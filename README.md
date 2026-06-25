# MAC Address Randomizer for Windows

Automatically randomizes the MAC address of a Windows network adapter on a configurable interval. Useful for privacy on public networks.

## Requirements

- Windows 10/11
- Python 3.11+
- **Administrator privileges** (required to write registry and toggle adapter)

## Usage

```powershell
# Run as Administrator — change MAC every 5 minutes (default)
python mac_randomizer.py

# Specify a different adapter and interval
python mac_randomizer.py --adapter "Ethernet" --interval 600

# Change MAC once and exit
python mac_randomizer.py --interval 0
```

To list available adapter names:
```powershell
Get-NetAdapter | Select-Object Name, InterfaceDescription
```

## How it works

1. Generates a random **locally-administered unicast** MAC address (first byte `0x02`).
2. Locates the adapter's registry entry by resolving its `InterfaceGuid` via PowerShell, then matching `NetCfgInstanceId` in `HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}`.
3. Disables the adapter, writes the new MAC to `NetworkAddress` in the registry, then re-enables the adapter.
4. Verifies the change by reading the live MAC back from `Get-NetAdapter`.

## Running tests

```powershell
pip install pytest
python -m pytest test_mac_randomizer.py -v
```

## Notes

- Not all network adapters support MAC address spoofing via the registry (e.g. some Wi-Fi drivers ignore `NetworkAddress`). Check your driver documentation.
- The original MAC is restored when the adapter driver resets (e.g. after a reboot), unless the registry value persists.
