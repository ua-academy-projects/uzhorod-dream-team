# Access from Windows and the router's network

The VMs run under libvirt **inside WSL2**, which itself sits behind NAT on the
laptop. Neither Windows nor a phone on the same Wi-Fi sees them by default.
This page opens exactly two things to the outside: the **UI** and the **bastion**.
The private network `192.168.77.0/24` stays closed on purpose.

```
 phone / laptop on the Wi-Fi
        │  http://<laptop IP>:5173          ssh -J jump@<laptop IP>:2222 …
        ▼
 Windows ── portproxy :5173 → 192.168.78.13:5173 (ui)
        │   portproxy :2222 → 192.168.78.5:22   (bastion)
        │   route 192.168.78.0/24 → WSL
        ▼
 WSL ── iptables FORWARD + MASQUERADE ──▶ virbr (crypto-edge) ──▶ ui, bastion
```

A real bridged adapter is not possible here: the VMs are behind double NAT
(libvirt inside WSL2), and a Wi-Fi access point drops frames with foreign MAC
addresses. The laptop works as a proxy instead.

## 1. WSL — after every `wsl --shutdown` or Windows reboot

```bash
ip -brief addr show eth0
```

Note the address (e.g. `172.30.164.145`): it is the gateway for step 2 and it
can change when WSL restarts.

```bash
sudo iptables -I FORWARD 1 -d 192.168.78.0/24 -j ACCEPT
```

```bash
sudo iptables -t nat -I POSTROUTING 1 ! -s 192.168.78.0/24 -d 192.168.78.0/24 -j MASQUERADE
```

- `FORWARD`: libvirt drops new connections that come into its network from outside.
- `MASQUERADE`: a VM has two interfaces; a request arrives on the edge network,
  but the reply would leave through the Vagrant management network (the default
  route) and get lost. Rewriting the source makes the reply come back the same way.

## 2. Windows — PowerShell as administrator

Route to the edge network through WSL (replace `<WSL_IP>` with the address from step 1):

```powershell
route add 192.168.78.0 mask 255.255.255.0 <WSL_IP>
```

The Hyper-V firewall blocks inbound traffic to WSL by default (Windows 11):

```powershell
Set-NetFirewallHyperVVMSetting -Name '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -DefaultInboundAction Allow
```

Check from Windows before going further — the UI must open here first:

```powershell
curl.exe -s http://192.168.78.13:5173/api/health
```

Expose the UI and the bastion on the laptop's own address:

```powershell
netsh interface portproxy add v4tov4 listenport=5173 listenaddress=0.0.0.0 connectport=5173 connectaddress=192.168.78.13
```

```powershell
netsh interface portproxy add v4tov4 listenport=2222 listenaddress=0.0.0.0 connectport=22 connectaddress=192.168.78.5
```

```powershell
New-NetFirewallRule -DisplayName "Crypto UI 5173" -Direction Inbound -Protocol TCP -LocalPort 5173 -Action Allow
```

```powershell
New-NetFirewallRule -DisplayName "Crypto bastion 2222" -Direction Inbound -Protocol TCP -LocalPort 2222 -Action Allow
```

Upgrading from the old layout (before the bastion, UI on `192.168.77.13`)? Remove
the old route and proxy first:

```powershell
route delete 192.168.77.0
```

```powershell
netsh interface portproxy delete v4tov4 listenport=5173 listenaddress=0.0.0.0
```

## 3. From the phone or another device

Find the laptop's address on the Wi-Fi:

```powershell
ipconfig
```

(the IPv4 address of the Wi-Fi adapter, e.g. `192.168.1.23`).

- **UI:** open `http://<laptop IP>:5173` on the phone.
- **SSH** from another computer: copy `.vagrant/bastion/id_ed25519` there, then

  ```bash
  ssh -i id_ed25519 -o ProxyCommand="ssh -i id_ed25519 -p 2222 -W %h:%p jump@<laptop IP>" vagrant@192.168.77.10
  ```

  `-i` applies to the last hop only, so plain `ssh -i key -J …` offers the wrong key to
  the bastion. Either name the key for both hops as above, or load it into the agent
  (`ssh-add id_ed25519`) and use `ssh -J jump@<laptop IP>:2222 vagrant@192.168.77.10`.

  The key opens these VMs only. `ssh -p 2222 jump@<laptop IP>` gives no shell — by design.

## 4. From anywhere — a quick Cloudflare tunnel

No account and no Windows steps. In WSL:

```bash
~/.local/bin/cloudflared tunnel --url http://192.168.78.13:5173
```

Open the `https://….trycloudflare.com` link from the log. `Ctrl+C` stops the tunnel.
The link is public — stop it after the demo.

## Troubleshooting

Walk the chain from Windows and stop where it breaks:

| check | if it fails |
|---|---|
| `ping <WSL_IP>` | WSL is not running |
| `ping 192.168.78.1` | route (step 2) or the Hyper-V firewall setting |
| `curl.exe http://192.168.78.13:5173` | iptables rules (step 1) — they vanish on `wsl --shutdown` |
| `http://<laptop IP>:5173` on the laptop itself | portproxy or the Windows firewall rule |
| the same on the phone | the network isolates clients — see below |

**Works on the laptop, not on the phone:** the laptop is on a **guest Wi-Fi** (or a
"Public" network) with client isolation — devices cannot see each other, even the
router's admin page does not open. Switch to the main network or turn isolation off
on the router.

`192.168.77.x` never answers from Windows: that is the private network, reachable
only through the bastion.

## What survives what

| setting | lost on |
|---|---|
| iptables rules (WSL) | `wsl --shutdown`, Windows reboot |
| route (Windows) | Windows reboot; also wrong after WSL changes its address |
| portproxy, firewall rules, Hyper-V setting | nothing — they stay until removed |
| Cloudflare tunnel | `Ctrl+C` or closing the terminal; the link changes on every start |

## Undo

```powershell
route delete 192.168.78.0
```

```powershell
netsh interface portproxy delete v4tov4 listenport=5173 listenaddress=0.0.0.0
```

```powershell
netsh interface portproxy delete v4tov4 listenport=2222 listenaddress=0.0.0.0
```

```powershell
Remove-NetFirewallRule -DisplayName "Crypto UI 5173"
```

```powershell
Remove-NetFirewallRule -DisplayName "Crypto bastion 2222"
```

```powershell
Set-NetFirewallHyperVVMSetting -Name '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -DefaultInboundAction Block
```

The last one matters: it is the only setting that never resets by itself.
In WSL the rules go away with `wsl --shutdown`, or now with `-D` instead of `-I`.
