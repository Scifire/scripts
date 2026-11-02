# Hetzner Robot NetBox Custom Script

Imports Hetzner dedicated servers from the Hetzner Robot Webservice into NetBox as a NetBox custom script.

The only supported script in this project is:

```text
netbox_custom_script_hetzner_robot.py
```

## Mapping

- NetBox site: `hetzner`
- NetBox device role slug: `server`
- Manufacturer: `Hetzner`
- Device type: one NetBox device type per Hetzner Robot product/model, for example `EX41` -> slug `ex41`
- Device asset tag: Hetzner Robot `server_number`
- Device location: Hetzner Robot datacenters are mapped to existing NetBox locations, for example `FSN1-DC8` -> `FSN1` > `DC8`
- Tenant: none
- Platform: none
- Interface: one generic `eth0`
- MAC address: not imported
- IPs: all IPv4 addresses exposed by Robot `/server` and `/ip`
- Primary IPv4: Robot `server_ip`
- Missing Robot servers: managed devices can be set to `decommissioning`

## Deploy

Copy the script to your NetBox scripts directory. The default source-install path is usually `/opt/netbox/netbox/scripts/`; adjust it if your installation uses a different `SCRIPTS_ROOT`.

```bash
cp netbox_custom_script_hetzner_robot.py <netbox-scripts-dir>/
chown netbox:netbox <netbox-scripts-dir>/netbox_custom_script_hetzner_robot.py
chmod 0644 <netbox-scripts-dir>/netbox_custom_script_hetzner_robot.py
```

## Configuration

Add Robot credentials and optional notification recipients to NetBox `configuration.py`:

```python
HETZNER_ROBOT_USER = "..."
HETZNER_ROBOT_PASSWORD = "..."
HETZNER_IMPORT_NOTIFY_EMAILS = "netbox-alerts@example.com"
```

Optional override:

```python
HETZNER_ROBOT_BASE_URL = "https://robot-ws.your-server.de"
```

`https://robot-ws.your-server.de` is Hetzner's real Robot Webservice endpoint.

Restart NetBox after configuration changes:

```bash
systemctl restart netbox netbox-rq
```

## Run

Open NetBox:

```text
Customization -> Scripts -> Import Hetzner Robot Dedicated Servers
```

Useful fields:

- `server_number`: import only one Robot server for testing
- `reassign_ips`: move existing IPs from another NetBox object to the imported server
- `decommission_missing`: during full syncs, set managed devices missing from Robot to `decommissioning`
- `notification_email`: recipients for failure and decommissioning emails; overrides `HETZNER_IMPORT_NOTIFY_EMAILS`

When `server_number` is set, the script skips decommissioning automatically.

## Schedule

For scheduled full syncs:

- leave `server_number` empty
- enable `decommission_missing`
- enable `Commit changes`
- schedule daily or every few hours as needed

Recommended schedule:

```text
Daily at 06:00
```

## Notifications

The script sends email when:

- the job fails
- one or more devices are set to `decommissioning`

Email uses NetBox's `EMAIL['FROM_EMAIL']` setting.

## Notes

The importer uses NetBox `asset_tag` as the sync key. If someone changes the asset tag manually, the next sync will treat the Hetzner server as a new device.

Per-server import failures are isolated: one bad server is logged and the rest continue importing. If any server fails, the job raises a summary exception at the end so the scheduled job still fails and sends a notification.
