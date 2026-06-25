"""
MAC Address Randomizer for Windows
Randomizes the MAC address of a network adapter on a configurable interval.
Requires Administrator privileges.
"""

import argparse
import ctypes
import random
import subprocess
import sys
import time
import winreg

# =========================
# SETTINGS
# =========================
DEFAULT_ADAPTER = "Wi-Fi"
DEFAULT_INTERVAL = 300  # seconds

NETWORK_CLASS_GUID = r"SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}"


# =========================
# PRIVILEGE CHECK
# =========================
def is_admin() -> bool:
    try:
        return ctypes.windll.shell32.IsUserAnAdmin() != 0
    except Exception:
        return False


# =========================
# RANDOM MAC GENERATOR
# =========================
def random_mac() -> str:
    """Generate a random locally-administered unicast MAC address."""
    octets = [
        0x02,  # Locally administered, unicast (bit 1 set, bit 0 clear)
        random.randint(0x00, 0xFF),
        random.randint(0x00, 0xFF),
        random.randint(0x00, 0xFF),
        random.randint(0x00, 0xFF),
        random.randint(0x00, 0xFF),
    ]
    return "".join(f"{b:02X}" for b in octets)


# =========================
# REGISTRY KEY LOOKUP
# =========================
def find_adapter_registry_key(friendly_name: str) -> str | None:
    """
    Find the registry subkey index whose DriverDesc or NetCfgInstanceId
    corresponds to the adapter with the given friendly name.

    Strategy: first resolve the friendly name → NetCfgInstanceId via
    PowerShell, then match that GUID in the registry. Falls back to a
    case-insensitive substring match on DriverDesc.
    """
    # Resolve GUID for the adapter via PowerShell
    ps_cmd = (
        f"(Get-NetAdapter -Name '{friendly_name}' -ErrorAction SilentlyContinue)"
        f".InterfaceGuid"
    )
    result = subprocess.run(
        ["powershell", "-NoProfile", "-Command", ps_cmd],
        capture_output=True, text=True
    )
    interface_guid = result.stdout.strip().upper().strip("{}")

    try:
        base_key = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, NETWORK_CLASS_GUID)
    except OSError as e:
        print(f"[-] Cannot open registry base key: {e}")
        return None

    with base_key:
        i = 0
        while True:
            try:
                subkey_name = winreg.EnumKey(base_key, i)
            except OSError:
                break
            i += 1

            subkey_path = f"{NETWORK_CLASS_GUID}\\{subkey_name}"
            try:
                subkey = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, subkey_path)
            except PermissionError:
                continue

            with subkey:
                # Try GUID match first (most reliable)
                if interface_guid:
                    try:
                        cfg_id, _ = winreg.QueryValueEx(subkey, "NetCfgInstanceId")
                        if cfg_id.upper().strip("{}") == interface_guid:
                            return subkey_name
                    except FileNotFoundError:
                        pass

                # Fallback: DriverDesc substring match
                try:
                    desc, _ = winreg.QueryValueEx(subkey, "DriverDesc")
                    if friendly_name.lower() in desc.lower():
                        return subkey_name
                except FileNotFoundError:
                    pass

    return None


# =========================
# ADAPTER CONTROL
# =========================
def set_adapter_state(adapter_name: str, enable: bool) -> bool:
    verb = "Enable" if enable else "Disable"
    cmd = f"{verb}-NetAdapter -Name '{adapter_name}' -Confirm:$false -ErrorAction Stop"
    result = subprocess.run(
        ["powershell", "-NoProfile", "-Command", cmd],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        action = "enable" if enable else "disable"
        print(f"[-] Failed to {action} adapter: {result.stderr.strip()}")
        return False
    return True


def write_mac_to_registry(reg_index: str, mac: str) -> bool:
    reg_path = (
        f"HKLM\\{NETWORK_CLASS_GUID}\\{reg_index}"
    )
    result = subprocess.run(
        ["reg", "add", reg_path, "/v", "NetworkAddress", "/d", mac, "/f"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f"[-] Registry write failed: {result.stderr.strip()}")
        return False
    return True


def get_current_mac(adapter_name: str) -> str | None:
    """Read the current MAC address from the live adapter."""
    ps_cmd = (
        f"(Get-NetAdapter -Name '{adapter_name}' -ErrorAction SilentlyContinue)"
        f".MacAddress"
    )
    result = subprocess.run(
        ["powershell", "-NoProfile", "-Command", ps_cmd],
        capture_output=True, text=True
    )
    mac = result.stdout.strip().replace("-", "").upper()
    return mac if mac else None


# =========================
# SINGLE ROTATION
# =========================
def rotate_mac(adapter_name: str) -> bool:
    """Change the MAC address once. Returns True on success."""
    new_mac = random_mac()
    print(f"\n[+] New MAC address: {new_mac}")

    reg_index = find_adapter_registry_key(adapter_name)
    if not reg_index:
        print(
            f"[-] Could not find registry key for adapter '{adapter_name}'.\n"
            f"    Run 'Get-NetAdapter' in PowerShell to confirm the exact adapter name."
        )
        return False

    if not set_adapter_state(adapter_name, enable=False):
        return False
    time.sleep(1)

    if not write_mac_to_registry(reg_index, new_mac):
        set_adapter_state(adapter_name, enable=True)
        return False

    if not set_adapter_state(adapter_name, enable=True):
        return False
    time.sleep(2)

    # Verify
    actual = get_current_mac(adapter_name)
    if actual and actual == new_mac:
        print(f"[+] MAC verified: {actual}")
    elif actual:
        print(f"[!] MAC mismatch — adapter reports {actual} (driver may normalise the address).")
    else:
        print("[!] Could not verify MAC — adapter may still be coming up.")

    return True


# =========================
# ENTRY POINT
# =========================
def main():
    parser = argparse.ArgumentParser(
        description="Randomize the MAC address of a Windows network adapter."
    )
    parser.add_argument(
        "-a", "--adapter",
        default=DEFAULT_ADAPTER,
        help=f"Friendly adapter name (default: {DEFAULT_ADAPTER!r}). "
             "Run 'Get-NetAdapter' in PowerShell to list adapters.",
    )
    parser.add_argument(
        "-i", "--interval",
        type=int,
        default=DEFAULT_INTERVAL,
        help=f"Seconds between MAC rotations (default: {DEFAULT_INTERVAL}). "
             "Use 0 to change once and exit.",
    )
    args = parser.parse_args()

    if not is_admin():
        print("[-] This script must be run as Administrator.")
        sys.exit(1)

    print(f"[*] MAC Randomizer started — adapter: {args.adapter!r}")
    if args.interval == 0:
        print("[*] Single-shot mode.")
    else:
        print(f"[*] Rotating every {args.interval} seconds. Press Ctrl+C to stop.")

    while True:
        try:
            rotate_mac(args.adapter)

            if args.interval == 0:
                break

            print(f"[+] Next rotation in {args.interval}s…")
            time.sleep(args.interval)

        except KeyboardInterrupt:
            print("\n[!] Stopped by user.")
            break
        except Exception as e:
            print(f"[-] Unexpected error: {e}")
            time.sleep(10)


if __name__ == "__main__":
    main()
