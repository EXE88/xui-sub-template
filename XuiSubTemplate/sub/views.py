import json
import os
from datetime import datetime
from pathlib import Path
from urllib.parse import quote, urlencode

from dotenv import load_dotenv
from django.db import connections
from django.shortcuts import render
from django.views import View

from .models import ClientUsageSnapshot

env_path = Path(__file__).resolve().parents[1] / ".env"
load_dotenv(env_path)


def _safe_json_loads(raw_value, default):
    try:
        return json.loads(raw_value) if raw_value else default
    except (TypeError, ValueError, json.JSONDecodeError):
        return default


def _find_client_and_inbound(subid):
    with connections["xui"].cursor() as cursor:
        cursor.execute(
            """
            SELECT id, protocol, port, listen, remark, settings, stream_settings
            FROM inbounds
            """
        )
        rows = cursor.fetchall()

    for row in rows:
        settings = _safe_json_loads(row[5], {})
        clients = settings.get("clients", [])
        for client in clients:
            if client.get("subId") == subid:
                inbound_data = {
                    "id": row[0],
                    "protocol": row[1],
                    "port": row[2],
                    "listen": row[3],
                    "remark": row[4],
                    "stream_settings": _safe_json_loads(row[6], {}),
                }
                return client, inbound_data
    return None, None


def _build_vless_config(client_data, inbound_data):
    client_id = client_data.get("id")
    if not client_id:
        return ""

    stream_settings = inbound_data.get("stream_settings") or {}
    network = stream_settings.get("network") or "tcp"
    security = stream_settings.get("security") or "none"

    host = ""
    port = inbound_data.get("port")

    external_proxies = stream_settings.get("externalProxy") or []
    if external_proxies and isinstance(external_proxies, list):
        proxy = external_proxies[0] or {}
        host = proxy.get("dest") or host
        port = proxy.get("port") or port

    if not host:
        host = inbound_data.get("listen") or os.getenv("XUI_SUBSERVICE_DOAMIN", "")

    if not host or not port:
        return ""

    params = [
        ("encryption", "none"),
        ("security", security),
        ("type", network),
    ]

    flow = client_data.get("flow")
    if flow:
        params.append(("flow", flow))

    if network == "tcp":
        tcp_settings = stream_settings.get("tcpSettings") or {}
        header = tcp_settings.get("header") or {}
        header_type = header.get("type")
        if header_type and header_type != "none":
            params.append(("headerType", header_type))
            request = header.get("request") or {}
            request_headers = request.get("headers") or {}
            hosts = request_headers.get("Host") or request_headers.get("host") or []
            paths = request.get("path") or []
            if hosts:
                if not isinstance(hosts, list):
                    hosts = [str(hosts)]
                params.append(("host", ",".join(hosts)))
            if paths:
                if isinstance(paths, list):
                    params.append(("path", str(paths[0])))
                else:
                    params.append(("path", str(paths)))
    elif network == "ws":
        ws_settings = stream_settings.get("wsSettings") or {}
        headers = ws_settings.get("headers") or {}
        ws_host = headers.get("Host") or headers.get("host")
        if ws_host:
            params.append(("host", ws_host))
        ws_path = ws_settings.get("path")
        if ws_path:
            params.append(("path", ws_path))
        early_data = ws_settings.get("maxEarlyData")
        if early_data:
            params.append(("ed", early_data))
        early_header = ws_settings.get("earlyDataHeaderName")
        if early_header:
            params.append(("eh", early_header))
    elif network == "grpc":
        grpc_settings = stream_settings.get("grpcSettings") or {}
        service_name = grpc_settings.get("serviceName")
        if service_name:
            params.append(("serviceName", service_name))
        authority = grpc_settings.get("authority")
        if authority:
            params.append(("authority", authority))
        multi_mode = grpc_settings.get("multiMode")
        if multi_mode is not None:
            params.append(("mode", "multi" if multi_mode else "gun"))
    elif network in {"httpupgrade", "splithttp", "xhttp"}:
        network_settings = stream_settings.get(f"{network}Settings") or {}
        upgrade_host = network_settings.get("host")
        if upgrade_host:
            params.append(("host", upgrade_host))
        upgrade_path = network_settings.get("path")
        if upgrade_path:
            params.append(("path", upgrade_path))

    if security == "tls":
        tls_settings = stream_settings.get("tlsSettings") or {}
        server_name = tls_settings.get("serverName")
        if server_name:
            params.append(("sni", server_name))
        alpn = tls_settings.get("alpn") or []
        if alpn:
            params.append(("alpn", ",".join(alpn)))
        fingerprint = tls_settings.get("fingerprint")
        if fingerprint:
            params.append(("fp", fingerprint))
        if tls_settings.get("allowInsecure"):
            params.append(("allowInsecure", "1"))
    elif security == "reality":
        reality_settings = stream_settings.get("realitySettings") or {}
        server_name = reality_settings.get("serverName")
        if server_name:
            params.append(("sni", server_name))
        fingerprint = reality_settings.get("fingerprint")
        if fingerprint:
            params.append(("fp", fingerprint))
        public_key = reality_settings.get("publicKey")
        if public_key:
            params.append(("pbk", public_key))
        short_id = reality_settings.get("shortId")
        if short_id:
            params.append(("sid", short_id))
        spider_x = reality_settings.get("spiderX")
        if spider_x:
            params.append(("spx", spider_x))

    query_string = urlencode(params, doseq=True, quote_via=quote, safe="")
    config_name = (
        client_data.get("comment")
        or client_data.get("email")
        or inbound_data.get("remark")
        or client_data.get("subId")
        or "config"
    )
    encoded_name = quote(str(config_name), safe="")

    return f"vless://{client_id}@{host}:{port}?{query_string}#{encoded_name}"


def build_client_config(client_data, inbound_data):
    protocol = (inbound_data or {}).get("protocol")
    if protocol == "vless":
        return _build_vless_config(client_data, inbound_data)
    return ""


class SubView(View):
    def get(self, request, subid):
        client_data, inbound_data = _find_client_and_inbound(subid)

        if not client_data:
            return render(
                request,
                "sub/SubViewPage.html",
                {
                    "error": "User not found",
                },
            )

        email = client_data.get("email")

        with connections["xui"].cursor() as cursor:
            cursor.execute(
                """
                SELECT up, down, expiry_time, last_online
                FROM client_traffics
                WHERE email = %s
                """,
                [email],
            )
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

        def to_iso(timestamp_ms):
            if not timestamp_ms or timestamp_ms <= 0:
                return None
            try:
                return datetime.utcfromtimestamp(timestamp_ms / 1000).isoformat() + "Z"
            except Exception:
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
            status = "expired" if expiry_time < now_ms else "active"
            expiry_iso = to_iso(expiry_time)

        last_online_iso = to_iso(last_seen)

        chart_limit = int(os.getenv("USAGE_CHART_LIMIT", "240"))
        if chart_limit < 1:
            chart_limit = 1

        snapshots = list(
            ClientUsageSnapshot.objects.filter(subid=subid).order_by("-recorded_at")[:chart_limit]
        )
        snapshots.reverse()

        usage_chart = [
            {
                "time": snapshot.recorded_at.isoformat(),
                "used": snapshot.used_mb,
            }
            for snapshot in snapshots
        ]

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
            "isUnlimitedQuota": total_quota == 0,
            "isUnlimitedTime": expiry_time == 0,
            "usageChart": usage_chart,
            "config": build_client_config(client_data, inbound_data),
        }

        return render(
            request,
            "sub/SubViewPage.html",
            {
                "demo_data_json": json.dumps(demo),
            },
        )
