"""
NetBox custom script: import Hetzner Robot dedicated servers.

Deploy this file into NetBox's scripts directory, for example:
  /opt/netbox/netbox/scripts/netbox_custom_script_hetzner_robot.py

Required environment variables on the NetBox worker:
  HETZNER_ROBOT_USER
  HETZNER_ROBOT_PASSWORD

Optional environment variables:
  HETZNER_ROBOT_BASE_URL=https://robot-ws.your-server.de
"""

import base64
import importlib
import json
import os
import re
import socket
import traceback
import urllib.error
import urllib.request
from dataclasses import dataclass
from ipaddress import ip_address, ip_network
from typing import Any

from dcim.models import Device, DeviceRole, DeviceType, Interface, Location, Manufacturer, Site
from django.conf import settings
from django.core.mail import send_mail
from extras.models import Tag
from extras.scripts import BooleanVar, Script, StringVar
from ipam.models import IPAddress


# Official Hetzner Robot Webservice endpoint, despite the example-looking hostname.
ROBOT_BASE_URL = "https://robot-ws.your-server.de"
DEFAULT_TAG_SLUG = "hetzner-robot"


class RobotApiError(RuntimeError):
    pass


def get_config_value(name: str, default: str = "") -> str:
    try:
        netbox_config = importlib.import_module("netbox.configuration")
        config_value = getattr(netbox_config, name, "") or ""
    except ImportError:
        config_value = ""

    return str(config_value or getattr(settings, name, "") or os.environ.get(name, default) or "").strip()


def require_env(name: str) -> str:
    value = get_config_value(name)
    if not value:
        raise RuntimeError(f"Missing required NetBox configuration setting or environment variable: {name}")
    normalized = value.strip("'").strip('"').lower()
    if normalized in {"replace_me", "changeme", "change_me"} or normalized.startswith("replace_with"):
        raise RuntimeError(f"Environment variable {name} still contains a placeholder value")
    return value


def slugify(value: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", value.strip().lower())
    return slug.strip("-") or "unknown"


def split_robot_datacenter(datacenter: str) -> tuple[str, str] | None:
    match = re.fullmatch(r"([A-Za-z]+\d+)[-_ ]+(DC\d+)", datacenter.strip(), re.IGNORECASE)
    if not match:
        return None
    return match.group(1).upper(), match.group(2).upper()


def as_list(value: Any) -> list[Any]:
    if value is None:
        return []
    if isinstance(value, list):
        return value
    return [value]


def unwrap_robot_entry(entry: Any, key: str) -> dict[str, Any]:
    if isinstance(entry, dict) and key in entry and isinstance(entry[key], dict):
        return entry[key]
    if isinstance(entry, dict):
        return entry
    return {}


def normalize_ip_address(value: str) -> str | None:
    value = str(value).strip()
    if not value:
        return None
    try:
        if "/" in value:
            network = ip_network(value, strict=False)
            if str(network.network_address) == value.split("/", 1)[0]:
                return None
            return str(network)
        addr = ip_address(value)
        prefix = 32 if addr.version == 4 else 128
        return f"{addr}/{prefix}"
    except ValueError:
        return None


def is_ipv4(address: str) -> bool:
    return ip_address(address.split("/", 1)[0]).version == 4


def robot_value(server: dict[str, Any], *names: str) -> Any:
    for name in names:
        value = server.get(name)
        if value not in (None, ""):
            return value
    return None


def parse_email_recipients(value: str) -> list[str]:
    recipients = []
    for item in re.split(r"[,;\s]+", value.strip()):
        if item and "@" in item:
            recipients.append(item)
    return recipients


def get_from_email() -> str:
    email_config = getattr(settings, "EMAIL", {}) or {}
    return email_config.get("FROM_EMAIL") or getattr(settings, "DEFAULT_FROM_EMAIL", "webmaster@localhost")


class RobotClient:
    def __init__(self, username: str, password: str, base_url: str = ROBOT_BASE_URL, timeout: int = 30) -> None:
        token = base64.b64encode(f"{username}:{password}".encode("utf-8")).decode("ascii")
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self.headers = {
            "Authorization": f"Basic {token}",
            "Accept": "application/json",
        }

    def get(self, path: str) -> Any:
        request = urllib.request.Request(
            f"{self.base_url}{path}",
            headers=self.headers,
            method="GET",
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                content = response.read()
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise RobotApiError(f"GET {path} failed with HTTP {exc.code}: {detail}") from exc
        except urllib.error.URLError as exc:
            raise RobotApiError(f"GET {path} failed: {exc.reason}") from exc

        if not content:
            return None
        return json.loads(content.decode("utf-8"))

    def servers(self) -> list[dict[str, Any]]:
        payload = self.get("/server")
        return [unwrap_robot_entry(item, "server") for item in as_list(payload)]

    def ips(self) -> list[dict[str, Any]]:
        try:
            payload = self.get("/ip")
        except RobotApiError:
            return []
        return [unwrap_robot_entry(item, "ip") for item in as_list(payload)]


@dataclass(frozen=True)
class RobotServer:
    server_number: str
    name: str
    model: str
    datacenter: str
    primary_ipv4: str | None
    ip_addresses: tuple[str, ...]


def parse_robot_servers(server_payloads: list[dict[str, Any]], ip_payloads: list[dict[str, Any]]) -> list[RobotServer]:
    ips_by_server_ip: dict[str, set[str]] = {}
    for ip_entry in ip_payloads:
        ip_value = robot_value(ip_entry, "ip", "address", "server_ip")
        server_ip = robot_value(ip_entry, "server_ip", "main_ip")
        normalized = normalize_ip_address(str(ip_value)) if ip_value else None
        if normalized and is_ipv4(normalized) and server_ip:
            ips_by_server_ip.setdefault(str(server_ip), set()).add(normalized)

    servers: list[RobotServer] = []
    for server in server_payloads:
        number = robot_value(server, "server_number", "id")
        if not number:
            continue

        primary_ipv4_raw = robot_value(server, "server_ip", "ip")
        primary_ipv4 = normalize_ip_address(str(primary_ipv4_raw)) if primary_ipv4_raw else None
        name = str(robot_value(server, "server_name", "name", "hostname") or f"hetzner-{number}")
        model = str(robot_value(server, "product", "model", "server_product") or "Dedicated Server")
        datacenter = str(robot_value(server, "dc", "datacenter", "location") or "")

        ip_addresses: set[str] = set()
        for key in ("server_ip", "ip", "primary_ip"):
            value = server.get(key)
            normalized = normalize_ip_address(str(value)) if value else None
            if normalized and is_ipv4(normalized):
                ip_addresses.add(normalized)

        for key in ("ips", "ip_addresses", "additional_ips"):
            for value in as_list(server.get(key)):
                if isinstance(value, dict):
                    value = robot_value(value, "ip", "address")
                normalized = normalize_ip_address(str(value)) if value else None
                if normalized and is_ipv4(normalized):
                    ip_addresses.add(normalized)

        if primary_ipv4_raw:
            ip_addresses.update(ips_by_server_ip.get(str(primary_ipv4_raw), set()))

        servers.append(
            RobotServer(
                server_number=str(number),
                name=name,
                model=model,
                datacenter=datacenter,
                primary_ipv4=primary_ipv4 if primary_ipv4 and is_ipv4(primary_ipv4) else None,
                ip_addresses=tuple(sorted(ip_addresses)),
            )
        )

    return servers


class HetznerRobotImport(Script):
    site_slug = StringVar(default="hetzner", description="NetBox site slug")
    device_role_slug = StringVar(default="server", description="NetBox device role slug")
    manufacturer_name = StringVar(default="Hetzner", description="NetBox manufacturer name")
    interface_name = StringVar(default="eth0", description="Interface name for imported IPs")
    tag_slug = StringVar(default=DEFAULT_TAG_SLUG, description="Tag used to identify importer-managed devices")
    notification_email = StringVar(
        required=False,
        description=(
            "Email recipient(s) for job failures and decommissioning alerts. "
            "Separate multiple addresses with commas. Falls back to HETZNER_IMPORT_NOTIFY_EMAILS."
        ),
    )
    server_number = StringVar(
        required=False,
        description="Optional Hetzner Robot server_number for a one-server import test",
    )
    reassign_ips = BooleanVar(
        default=False,
        description="Move existing IP addresses if they are assigned to another object",
    )
    decommission_missing = BooleanVar(
        default=True,
        description="Set missing managed devices to decommissioning. Skipped automatically for one-server imports.",
    )

    class Meta:
        name = "Import Hetzner Robot Dedicated Servers"
        description = "Import dedicated servers from Hetzner Robot into NetBox."
        field_order = (
            "site_slug",
            "device_role_slug",
            "manufacturer_name",
            "interface_name",
            "tag_slug",
            "notification_email",
            "server_number",
            "reassign_ips",
            "decommission_missing",
        )

    def run(self, data: dict[str, Any], commit: bool) -> None:
        configured_recipients = data.get("notification_email") or get_config_value("HETZNER_IMPORT_NOTIFY_EMAILS")
        self.notification_recipients = parse_email_recipients(configured_recipients)
        self.commit = commit

        try:
            return self.run_import(data, commit)
        except Exception as exc:
            self.send_failure_email(exc)
            raise

    def run_import(self, data: dict[str, Any], commit: bool) -> None:
        self.site = Site.objects.get(slug=data.get("site_slug") or "hetzner")
        self.role = DeviceRole.objects.get(slug=slugify(data.get("device_role_slug") or "server"))
        self.manufacturer = self.ensure_manufacturer(data.get("manufacturer_name") or "Hetzner")
        self.tag = self.ensure_tag(data.get("tag_slug") or DEFAULT_TAG_SLUG)
        self.interface_name = data.get("interface_name") or "eth0"
        self.reassign_ips = bool(data.get("reassign_ips", False))
        self.decommissioned_devices: list[str] = []

        if not commit:
            self.log_warning("Dry-run mode: NetBox will roll back all database changes from this script run.")

        robot = RobotClient(
            username=require_env("HETZNER_ROBOT_USER"),
            password=require_env("HETZNER_ROBOT_PASSWORD"),
            base_url=get_config_value("HETZNER_ROBOT_BASE_URL", ROBOT_BASE_URL),
        )
        servers = parse_robot_servers(robot.servers(), robot.ips())

        requested_server = (data.get("server_number") or "").strip()
        partial_sync = bool(requested_server)
        if requested_server:
            servers = [server for server in servers if server.server_number == requested_server]
            if not servers:
                raise RuntimeError(f"Robot server_number not found: {requested_server}")

        self.device_type_cache: dict[str, DeviceType] = {}
        self.location_cache: dict[str, Location] = {}

        failed_servers: list[str] = []
        for server in servers:
            try:
                self.import_server(server)
            except Exception as exc:
                failed_servers.append(f"{server.server_number} {server.name}: {type(exc).__name__}: {exc}")
                self.log_failure(
                    f"Failed importing server {server.server_number} {server.name}: {type(exc).__name__}: {exc}"
                )

        if partial_sync:
            self.log_info("Skipping decommission check because this is a one-server import.")
        elif bool(data.get("decommission_missing", True)):
            self.decommission_missing_devices({server.server_number for server in servers})

        self.send_decommission_email()
        self.log_success(f"Processed {len(servers)} Hetzner Robot servers.")
        if failed_servers:
            raise RuntimeError(
                "One or more Hetzner Robot servers failed to import:\n"
                + "\n".join(f"- {server}" for server in failed_servers)
            )

    def ensure_manufacturer(self, name: str) -> Manufacturer:
        manufacturer, created = Manufacturer.objects.get_or_create(
            slug=slugify(name),
            defaults={"name": name},
        )
        if created:
            self.log_success(f"Created manufacturer {name}")
        return manufacturer

    def ensure_tag(self, slug: str) -> Tag:
        tag, created = Tag.objects.get_or_create(
            slug=slug,
            defaults={"name": slug},
        )
        if created:
            self.log_success(f"Created tag {slug}")
        return tag

    def device_type_for_model(self, model: str) -> DeviceType:
        slug = slugify(model)
        if slug in self.device_type_cache:
            return self.device_type_cache[slug]

        device_type, created = DeviceType.objects.get_or_create(
            manufacturer=self.manufacturer,
            slug=slug,
            defaults={"model": model},
        )
        if created:
            self.log_success(f"Created device type {model}")
        self.device_type_cache[slug] = device_type
        return device_type

    def location_for_datacenter(self, datacenter: str) -> Location | None:
        datacenter = datacenter.strip()
        if not datacenter:
            return None

        slug = slugify(datacenter)
        if slug in self.location_cache:
            return self.location_cache[slug]

        exact = Location.objects.filter(site=self.site, slug=slug).first()
        if exact:
            self.location_cache[slug] = exact
            return exact

        split = split_robot_datacenter(datacenter)
        if split:
            parent_name, child_name = split
            parent, parent_created = Location.objects.get_or_create(
                site=self.site,
                slug=slugify(parent_name),
                defaults={"name": parent_name, "status": "active"},
            )
            if parent_created:
                self.log_success(f"Created location {parent_name}")

            child, child_created = Location.objects.get_or_create(
                site=self.site,
                parent=parent,
                slug=slugify(child_name),
                defaults={"name": child_name, "status": "active"},
            )
            if child_created:
                self.log_success(f"Created location {parent_name} > {child_name}")
            self.location_cache[slug] = child
            return child

        location, created = Location.objects.get_or_create(
            site=self.site,
            slug=slug,
            defaults={"name": datacenter, "status": "active"},
        )
        if created:
            self.log_success(f"Created location {datacenter}")
        self.location_cache[slug] = location
        return location

    def import_server(self, server: RobotServer) -> None:
        device = self.ensure_device(server)
        interface = self.ensure_interface(device)
        imported_ips = [self.ensure_ip(address, interface, server) for address in server.ip_addresses]
        self.set_primary_ip(device, server, imported_ips)

    def ensure_device(self, server: RobotServer) -> Device:
        device_type = self.device_type_for_model(server.model)
        location = self.location_for_datacenter(server.datacenter)
        device = Device.objects.filter(asset_tag=server.server_number).first()

        if device:
            changed = self.update_fields(
                device,
                {
                    "name": server.name,
                    "site": self.site,
                    "role": self.role,
                    "device_type": device_type,
                    "status": "active",
                    "location": location,
                },
            )
            if changed:
                self.save_model(device, f"Updated device {server.server_number} {server.name}")
        else:
            device = Device(
                name=server.name,
                site=self.site,
                role=self.role,
                device_type=device_type,
                status="active",
                asset_tag=server.server_number,
                location=location,
            )
            self.save_model(device, f"Created device {server.server_number} {server.name}")

        if self.tag not in device.tags.all():
            device.tags.add(self.tag)
            self.log_info(f"Tagged device {server.server_number} with {self.tag.slug}")
        return device

    def ensure_interface(self, device: Device) -> Interface:
        interface, created = Interface.objects.get_or_create(
            device=device,
            name=self.interface_name,
            defaults={"type": "1000base-t", "enabled": True},
        )
        if created:
            self.log_success(f"Created interface {device.name} {self.interface_name}")
            return interface

        changed = self.update_fields(interface, {"type": "1000base-t", "enabled": True})
        if changed:
            self.save_model(interface, f"Updated interface {device.name} {self.interface_name}")
        return interface

    def ensure_ip(self, address: str, interface: Interface, server: RobotServer) -> IPAddress:
        ip_obj = IPAddress.objects.filter(address=address).first()
        if ip_obj:
            assigned_object = getattr(ip_obj, "assigned_object", None)
            if assigned_object and assigned_object != interface:
                if not self.reassign_ips:
                    self.log_warning(
                        f"IP {address} is already assigned to {assigned_object}; not moving it."
                    )
                    return ip_obj
                self.clear_primary_ip_before_reassign(ip_obj)

            changed = self.update_fields(
                ip_obj,
                {
                    "status": "active",
                    "assigned_object": interface,
                    "description": f"Hetzner Robot server {server.server_number}",
                },
            )
            if changed:
                self.save_model(ip_obj, f"Updated IP {address}")
        else:
            ip_obj = IPAddress(
                address=address,
                status="active",
                description=f"Hetzner Robot server {server.server_number}",
            )
            ip_obj.assigned_object = interface
            self.save_model(ip_obj, f"Created IP {address}")

        if self.tag not in ip_obj.tags.all():
            ip_obj.tags.add(self.tag)
        return ip_obj

    def clear_primary_ip_before_reassign(self, ip_obj: IPAddress) -> None:
        for device in Device.objects.filter(primary_ip4=ip_obj):
            device.primary_ip4 = None
            self.save_model(device, f"Cleared primary IPv4 on {device.name} before reassigning {ip_obj.address}")
        for device in Device.objects.filter(primary_ip6=ip_obj):
            device.primary_ip6 = None
            self.save_model(device, f"Cleared primary IPv6 on {device.name} before reassigning {ip_obj.address}")

    def set_primary_ip(self, device: Device, server: RobotServer, imported_ips: list[IPAddress]) -> None:
        primary_ip4 = None
        for ip_obj in imported_ips:
            if server.primary_ipv4 and str(ip_obj.address) == server.primary_ipv4:
                primary_ip4 = ip_obj
                break

        if primary_ip4 and device.primary_ip4_id != primary_ip4.id:
            device.primary_ip4 = primary_ip4
            self.save_model(device, f"Set primary IPv4 for {device.name} to {primary_ip4.address}")

    def decommission_missing_devices(self, active_server_numbers: set[str]) -> None:
        devices = Device.objects.filter(site=self.site, tags__slug=self.tag.slug).exclude(
            asset_tag__in=active_server_numbers
        )
        for device in devices:
            if device.status != "decommissioning":
                device.status = "decommissioning"
                self.save_model(device, f"Marked missing Hetzner device {device.asset_tag} as decommissioning")
                self.decommissioned_devices.append(f"{device.name} asset_tag={device.asset_tag}")

    def update_fields(self, obj: Any, desired: dict[str, Any]) -> bool:
        changed = False
        for field_name, value in desired.items():
            if getattr(obj, field_name) != value:
                setattr(obj, field_name, value)
                changed = True
        return changed

    def save_model(self, obj: Any, message: str) -> None:
        obj.full_clean()
        obj.save()
        self.log_success(message)

    def send_failure_email(self, exc: Exception) -> None:
        if not self.notification_recipients:
            return
        subject = "[NetBox] Hetzner Robot import failed"
        body = "\n".join(
            [
                "The NetBox Hetzner Robot import script failed.",
                "",
                f"Host: {socket.getfqdn()}",
                f"Script: {self.Meta.name}",
                f"Exception: {type(exc).__name__}: {exc}",
                "",
                traceback.format_exc(),
            ]
        )
        try:
            send_mail(subject, body, get_from_email(), self.notification_recipients, fail_silently=False)
        except Exception as mail_exc:
            self.log_failure(f"Could not send failure notification email: {mail_exc}")

    def send_decommission_email(self) -> None:
        if not self.commit or not self.notification_recipients or not self.decommissioned_devices:
            return
        subject = "[NetBox] Hetzner devices marked decommissioning"
        body = "\n".join(
            [
                "The NetBox Hetzner Robot import marked device(s) as decommissioning.",
                "",
                f"Host: {socket.getfqdn()}",
                f"Script: {self.Meta.name}",
                "",
                "Devices:",
                *[f"- {device}" for device in self.decommissioned_devices],
            ]
        )
        try:
            send_mail(subject, body, get_from_email(), self.notification_recipients, fail_silently=False)
            self.log_success(f"Sent decommissioning notification to {', '.join(self.notification_recipients)}")
        except Exception as mail_exc:
            self.log_failure(f"Could not send decommissioning notification email: {mail_exc}")
