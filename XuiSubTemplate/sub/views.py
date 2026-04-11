import json
import os
import base64
import re
from pathlib import Path
import requests
from dotenv import load_dotenv
from django.shortcuts import render
from django.views import View
from django.db import connections
from datetime import datetime

from .models import ClientUsageSnapshot

env_path = Path(__file__).resolve().parents[1] / '.env'
load_dotenv(env_path)


CONFIG_USAGE_SUFFIX_PATTERN = re.compile(
    r"-(?:\d+(?:\.\d+)?)MB(?:%F0%9F%93%8A|📊)$",
    re.IGNORECASE,
)


def sanitize_config_name_suffix(config_text):
    """
    Remove usage suffixes like '-828.21MB📊' from the URL fragment part of each config line.
    """
    cleaned_lines = []
    for raw_line in config_text.splitlines():
        line = raw_line.strip()
        if not line:
            continue

        if "#" not in line:
            cleaned_lines.append(line)
            continue

        prefix, fragment = line.rsplit("#", 1)
        cleaned_fragment = CONFIG_USAGE_SUFFIX_PATTERN.sub("", fragment)
        cleaned_lines.append(f"{prefix}#{cleaned_fragment}")

    return "\n".join(cleaned_lines)


class SubView(View):
    def get(self, request, subid):
        client_data = None

        with connections['xui'].cursor() as cursor:
            cursor.execute("SELECT settings FROM inbounds")
            rows = cursor.fetchall()

        for row in rows:
            try:
                data = json.loads(row[0])
                clients = data.get("clients", [])

                for c in clients:
                    if c.get("subId") == subid:
                        client_data = c
                        break

                if client_data:
                    break
            except:
                continue

        if not client_data:
            return render(request, 'sub/SubViewPage.html', {
                "error": "User not found"
            })

        email = client_data.get("email")

        with connections['xui'].cursor() as cursor:
            cursor.execute("""
                SELECT up, down, expiry_time, last_online
                FROM client_traffics
                WHERE email = %s
            """, [email])

            traffic = cursor.fetchone()

        if traffic:
            uploaded = traffic[0] or 0
            downloaded = traffic[1] or 0
            expiry_time = traffic[2] if traffic[2] is not None else 0
            last_seen = traffic[3]
        else:
            uploaded = downloaded = 0
            expiry_time = 0
            last_seen = None

        total_used = uploaded + downloaded
        total_quota = client_data.get("totalGB", 0)
        remained = max(total_quota - total_used, 0)

        now_ms = int(datetime.utcnow().timestamp() * 1000)
        
        def to_iso(ts):
            if not ts or ts <= 0:
                return None
            try:
                return datetime.utcfromtimestamp(ts / 1000).isoformat() + "Z"
            except:
                return None

        if not client_data.get("enable", True):
            status = "deactive"
            expiry_iso = None

        elif expiry_time == 0:
            status = "active"
            expiry_iso = None

        elif expiry_time < 0:
            status = "expired"
            expiry_iso = None

        else:
            if expiry_time < now_ms:
                status = "expired"
            else:
                status = "active"

            expiry_iso = to_iso(expiry_time)

        last_online_iso = to_iso(last_seen)

        chart_limit = int(os.getenv("USAGE_CHART_LIMIT", "240"))
        if chart_limit < 1:
            chart_limit = 1
        snapshots = list(
            ClientUsageSnapshot.objects.filter(subid=subid)
            .order_by("-recorded_at")[:chart_limit]
        )
        snapshots.reverse()

        usage_chart = [
            {
                "time": snapshot.recorded_at.isoformat(),
                "used": snapshot.used_mb,
            }
            for snapshot in snapshots
        ]

        protocol = os.getenv("XUI_SUBSERVICE_PROTOCOL", "http")
        domain = os.getenv("XUI_SUBSERVICE_DOAMIN", "")
        port = os.getenv("XUI_SUBSERVICE_PORT", "")

        config = ""
        if domain and port:
            sub_url = f"{protocol}://{domain}:{port}/sub/{subid}"
            try:
                response = requests.get(sub_url, timeout=10)
                response.raise_for_status()
                encoded_config = response.text.strip()

                # Normalize Base64 payload in case padding is missing.
                missing_padding = len(encoded_config) % 4
                if missing_padding:
                    encoded_config += "=" * (4 - missing_padding)

                decoded_config = base64.b64decode(encoded_config).decode("utf-8")
                config = sanitize_config_name_suffix(decoded_config)
            except Exception:
                config = ""

        is_unlimited_quota = total_quota == 0
        is_unlimited_time = expiry_time == 0

        demo = {
            "subId": subid,
            "status": status,
            "downloaded": downloaded,
            "uploaded": uploaded,
            "totalUsed": total_used,
            "totalQuota": total_quota,
            "remained": remained,
            "lastOnline": last_online_iso,
            "expiry": expiry_iso,
            "isUnlimitedQuota": is_unlimited_quota,
            "isUnlimitedTime": is_unlimited_time,
            "usageChart": usage_chart,
            "config": config
        }

        return render(request, 'sub/SubViewPage.html', {
            "demo_data_json": json.dumps(demo)
        })
