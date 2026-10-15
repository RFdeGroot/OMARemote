# Field limits

Every text field in OMARemote takes at most so many characters (`maximumLength`), so that a script
pasted by mistake never ends up in a host name, and a file that arrives by import or sync holds no
more than a field could. The numbers live in two places that a test keeps equal:
`ui/js/Limits.js` (the fields) and `LIMITS` in `bin/omaremote-session` (import and sync).

Each limit is the largest value a real system takes, with room to spare. Counted as Qt counts
`maximumLength`: in UTF-16 units, so an emoji counts as two.

| Limit | Characters | Fields | The largest real value |
| --- | --- | --- | --- |
| `host` | 253 | host, gateway | DNS: 255 octets on the wire, 253 written out ([RFC 1035 §2.3.4](https://datatracker.ietf.org/doc/html/rfc1035)); `check_host` takes no more |
| `address` | 1024 | quick connect, search | scheme + user + host + port |
| `hostList` | 2048 | KDCs | several host names |
| `user` | 1024 | user names | Windows 513 (`CRED_MAX_USERNAME_LENGTH`, [CREDENTIALW](https://learn.microsoft.com/en-us/windows/win32/api/wincred/ns-wincred-credentialw)); AD UPNs up to 1024 ([TechNet](https://learn.microsoft.com/en-us/archive/technet-wiki/52250.active-directory-user-principal-name)); Linux 256 (`getconf LOGIN_NAME_MAX`) |
| `domain` | 512 | domains | DNS 255; AD in practice 64, NetBIOS 15 ([KB 909264](https://learn.microsoft.com/troubleshoot/windows-server/identity/naming-conventions-for-computer-domain-site-ou)); Windows target names 337 (CREDENTIALW) |
| `password` | 2048 | passwords | Windows 256 in FreeRDP's WinPR (`CREDUI_MAX_PASSWORD_LENGTH`), up to 1280 in Windows' credential store (5×512 bytes, CREDENTIALW); SSH sets no limit |
| `port` | 5 | port | 65535 |
| `size` | 5 | width, height | 8192 a monitor, 32766 together ([IMsTscAx](https://learn.microsoft.com/en-us/windows/win32/termserv/imstscax-desktopheight), FreeRDP `disp.h`) |
| `args` | 4096 | ssh and FreeRDP options | room for `-o ProxyCommand=…` |
| `path` | 4096 | sync folder, export path | `PATH_MAX` |
| `name` | 256 | connection, group and system names | our own labels |
| `shortcut` | 128 | shortcut fields | `SUPER + CTRL + ALT + SHIFT + …` |
| `standard` | 256 | any field that names none of these | |

A paste reads at most 16 KiB (the longest field as UTF-8). One that would not fit the field is
refused whole, with a hint, rather than cut to what fits. Pasting into a session (RDP, VNC, SSH)
goes another way and has none of these limits.
