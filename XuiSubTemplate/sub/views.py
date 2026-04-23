import json
import os
from datetime import datetime
from pathlib import Path
from urllib.parse import parse_qsl, quote, urlencode, urlsplit

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


def _to_string_list(value):
    if value is None:
        return []
    if isinstance(value, (list, tuple, set)):
        return [str(item).strip() for item in value if str(item).strip()]
    text = str(value).strip()
    return [text] if text else []


def _pick_header_value(headers, *names):
    if not isinstance(headers, dict):
        return ""

    lowered = {str(key).lower(): value for key, value in headers.items()}
    for name in names:
        value = lowered.get(str(name).lower())
        values = _to_string_list(value)
        if values:
            return ",".join(values)
    return ""


def _normalize_path(raw_path, default="/"):
    values = _to_string_list(raw_path)
    if not values:
        return default

    path = values[0]
    if path.startswith(("ws://", "wss://", "http://", "https://")):
        parsed = urlsplit(path)
        path = parsed.path or "/"
        if parsed.query:
            path = f"{path}?{parsed.query}"

    if not path.startswith("/"):
        path = f"/{path.lstrip('/')}"

    return path or default


def _extract_path_metadata(raw_path):
    values = _to_string_list(raw_path)
    original_path = values[0] if values else ""
    metadata = {}

    if original_path.startswith(("ws://", "wss://", "http://", "https://")):
        absolute_url = urlsplit(original_path)
        if absolute_url.netloc:
            metadata["host"] = absolute_url.netloc.strip()

    normalized_path = _normalize_path(raw_path, default="/")
    parsed = urlsplit(normalized_path)

    cleaned_query = []
    for key, value in parse_qsl(parsed.query, keep_blank_values=True):
        normalized_key = key.lower()
        if normalized_key == "host" and value:
            metadata.setdefault("host", value.strip())
            continue
        if normalized_key in {"ed", "maxearlydata"} and value:
            metadata.setdefault("ed", value.strip())
            continue
        if normalized_key in {"eh", "earlydataheadername"} and value:
            metadata.setdefault("eh", value.strip())
            continue
        cleaned_query.append((key, value))

    cleaned_path = parsed.path or "/"
    if cleaned_query:
        cleaned_path = f"{cleaned_path}?{urlencode(cleaned_query, doseq=True, quote_via=quote, safe='')}"

    return cleaned_path, metadata


def _resolve_remote_host_and_port(inbound_data):
    stream_settings = inbound_data.get("stream_settings") or {}
    host = ""
    port = inbound_data.get("port")

    external_proxies = stream_settings.get("externalProxy") or []
    if external_proxies and isinstance(external_proxies, list):
        proxy = external_proxies[0] or {}
        host = str(proxy.get("dest") or "").strip()
        port = proxy.get("port") or port

    listen = str(inbound_data.get("listen") or "").strip()
    if not host and listen and listen not in {"0.0.0.0", "::", "[::]", "*"}:
        host = listen

    if not host:
        host = os.getenv("XUI_SUBSERVICE_DOAMIN", "").strip()

    return host, port


def _append_param(params, key, value):
    values = _to_string_list(value)
    if values:
        params.append((key, ",".join(values)))


def _pick_primary_value(*values):
    for value in values:
        items = _to_string_list(value)
        if items:
            return items[0]
    return ""


def _build_config_name(client_data, inbound_data):
    comment = _pick_primary_value(client_data.get("comment"))
    if comment:
        return comment

    inbound_remark = _pick_primary_value(inbound_data.get("remark"))
    email = _pick_primary_value(client_data.get("email"))
    subid = _pick_primary_value(client_data.get("subId"))

    if inbound_remark and email:
        return f"{inbound_remark}-{email}"
    if inbound_remark and subid:
        return f"{inbound_remark}-{subid}"
    return email or inbound_remark or subid or "config"


def _extract_transport_params(stream_settings, network):
    params = []

    if network == "tcp":
        tcp_settings = stream_settings.get("tcpSettings") or {}
        header = tcp_settings.get("header") or {}
        header_type = header.get("type")
        if header_type and header_type != "none":
            params.append(("headerType", header_type))
            request = header.get("request") or {}
            request_headers = request.get("headers") or {}
            _append_param(params, "host", _pick_header_value(request_headers, "Host"))
            tcp_path = _normalize_path(request.get("path"), default="")
            if tcp_path:
                params.append(("path", tcp_path))
    elif network == "ws":
        ws_settings = stream_settings.get("wsSettings") or {}
        headers = ws_settings.get("headers") or {}
        ws_path, path_metadata = _extract_path_metadata(ws_settings.get("path"))
        ws_host = (
            path_metadata.get("host")
            or _pick_primary_value(ws_settings.get("host"))
            or _pick_header_value(headers, "Host")
        )
        if ws_host:
            params.append(("host", ws_host))
        if ws_path:
            params.append(("path", ws_path))
        early_data = path_metadata.get("ed") or ws_settings.get("maxEarlyData")
        if early_data:
            params.append(("ed", early_data))
        early_header = path_metadata.get("eh") or ws_settings.get("earlyDataHeaderName")
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
    elif network in {"http", "h2"}:
        http_settings = stream_settings.get("httpSettings") or {}
        _append_param(params, "host", http_settings.get("host"))
        http_path = _normalize_path(http_settings.get("path"), default="/")
        if http_path:
            params.append(("path", http_path))
    elif network in {"httpupgrade", "splithttp", "xhttp"}:
        network_settings = stream_settings.get(f"{network}Settings") or {}
        upgrade_path, path_metadata = _extract_path_metadata(network_settings.get("path"))
        upgrade_host = path_metadata.get("host") or network_settings.get("host")
        if upgrade_host:
            _append_param(params, "host", upgrade_host)
        if upgrade_path:
            params.append(("path", upgrade_path))
        if path_metadata.get("ed"):
            params.append(("ed", path_metadata["ed"]))
        if path_metadata.get("eh"):
            params.append(("eh", path_metadata["eh"]))

    return params


def _extract_security_params(stream_settings, security):
    params = []

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

    return params


def _extract_vless_profile(client_data, inbound_data):
    client_id = client_data.get("id")
    if not client_id:
        return None

    stream_settings = inbound_data.get("stream_settings") or {}
    network = stream_settings.get("network") or "tcp"
    security = stream_settings.get("security") or "none"
    address, port = _resolve_remote_host_and_port(inbound_data)

    if not address or not port:
        return None

    params = [
        ("encryption", "none"),
        ("security", security),
        ("type", network),
    ]

    flow = client_data.get("flow")
    if flow:
        params.append(("flow", flow))

    params.extend(_extract_transport_params(stream_settings, network))
    params.extend(_extract_security_params(stream_settings, security))

    return {
        "scheme": "vless",
        "id": client_id,
        "address": address,
        "port": port,
        "params": params,
        "name": _build_config_name(client_data, inbound_data),
    }


def _build_uri_from_profile(profile):
    if not profile:
        return ""

    query_string = urlencode(profile["params"], doseq=True, quote_via=quote, safe="")
    encoded_name = quote(str(profile["name"]), safe="")
    return (
        f'{profile["scheme"]}://{profile["id"]}@{profile["address"]}:{profile["port"]}'
        f'?{query_string}#{encoded_name}'
    )


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
    return _build_uri_from_profile(_extract_vless_profile(client_data, inbound_data))


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
