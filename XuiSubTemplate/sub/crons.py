import json
import logging

from django.db import connections
from django.db.models import Max
from django.utils import timezone

from .models import ClientUsageSnapshot

logger = logging.getLogger(__name__)


def _to_int(value, default=0):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _load_eligible_clients(now_ms):
    """
    Read clients from inbounds.settings and return clients that are enabled and not time-expired.
    Users with totalGB=0 and/or expiryTime=0 are considered unlimited and should be included.
    Quota check is done later using client_traffics counters.
    """
    clients_by_email = {}

    with connections["xui"].cursor() as cursor:
        cursor.execute("SELECT enable, settings FROM inbounds")
        rows = cursor.fetchall()

    for inbound_enable, settings_json in rows:
        if not inbound_enable or not settings_json:
            continue

        try:
            settings = json.loads(settings_json)
        except (TypeError, ValueError, json.JSONDecodeError):
            continue

        for client in settings.get("clients", []):
            email = client.get("email")
            subid = client.get("subId")

            if not email or not subid:
                continue

            if not client.get("enable", True):
                continue

            total_gb = _to_int(client.get("totalGB"), 0)
            expiry_time = _to_int(client.get("expiryTime"), 0)

            # expiryTime == 0 means unlimited time in 3x-ui.
            if expiry_time < 0:
                continue
            if expiry_time > 0 and expiry_time <= now_ms:
                continue

            clients_by_email[email] = {
                "email": email,
                "subid": subid,
                "total_gb": total_gb,
            }

    return clients_by_email


def record_clients_usage():
    now = timezone.now()
    now_ms = int(now.timestamp() * 1000)
    eligible_clients = _load_eligible_clients(now_ms)

    if not eligible_clients:
        logger.info("record_clients_usage: no eligible clients found")
        return

    with connections["xui"].cursor() as cursor:
        cursor.execute("SELECT email, up, down, enable FROM client_traffics")
        traffic_rows = cursor.fetchall()

    candidates = []
    for email, up, down, traffic_enable in traffic_rows:
        client = eligible_clients.get(email)
        if not client:
            continue

        if traffic_enable is not None and int(traffic_enable) == 0:
            continue

        up = _to_int(up, 0)
        down = _to_int(down, 0)
        total_used_bytes = up + down

        # totalGB == 0 means unlimited quota in 3x-ui.
        total_limit_bytes = client["total_gb"]
        if total_limit_bytes > 0 and total_used_bytes >= total_limit_bytes:
            continue

        candidates.append(
            {
                "subid": client["subid"],
                "email": email,
                "total_used_bytes": total_used_bytes,
            }
        )

    if not candidates:
        logger.info("record_clients_usage: no active clients after traffic checks")
        return

    subids = list({item["subid"] for item in candidates})
    latest_ids = (
        ClientUsageSnapshot.objects.filter(subid__in=subids)
        .values("subid")
        .annotate(last_id=Max("id"))
    )
    latest_id_list = [item["last_id"] for item in latest_ids if item.get("last_id")]
    latest_snapshots = ClientUsageSnapshot.objects.filter(id__in=latest_id_list)
    latest_by_subid = {snapshot.subid: snapshot for snapshot in latest_snapshots}

    to_create = []
    for item in candidates:
        previous = latest_by_subid.get(item["subid"])
        previous_total = previous.total_used_bytes if previous else item["total_used_bytes"]
        period_used_bytes = max(item["total_used_bytes"] - previous_total, 0)
        period_used_mb = round(period_used_bytes / (1024 * 1024), 3)

        to_create.append(
            ClientUsageSnapshot(
                subid=item["subid"],
                email=item["email"],
                used_mb=period_used_mb,
                total_used_bytes=item["total_used_bytes"],
            )
        )

    ClientUsageSnapshot.objects.bulk_create(to_create, batch_size=1000)
    logger.info("record_clients_usage: created %s snapshots", len(to_create))
