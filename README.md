# Carry

**Личный VPN-сервер одной командой.** · [English below](#english)

Carry ставит на чистый сервер Ubuntu протокол VLESS + Reality (Xray-core) и, если попросить, запасной Hysteria2. Веб-панели нет: заходить некуда, ломать нечего. В конце вы получаете QR-код, сканируете его телефоном, и VPN работает.

## Установка

1. Купите VPS с **Ubuntu 22.04 или 24.04** (подойдёт самый дешёвый тариф, например у OVH).
2. Откройте консоль сервера: веб-консоль (KVM) в панели хостера или SSH, в том числе с телефона через Termius.
3. Вставьте одну команду и нажмите Enter:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/cookiefbi/carry/main/install.sh)
```

С запасным протоколом Hysteria2:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/cookiefbi/carry/main/install.sh) --hy2
```

Вопросов не будет. Через 1–3 минуты на экране появятся крупное «ГОТОВО», QR-код и ссылки. То же самое сохраняется в файл `/root/carry.txt`.

> Если вы зашли не под root, сначала выполните `sudo -i`.

## Какое приложение скачать

| Устройство | Приложение |
|---|---|
| Android | v2rayNG или Hiddify |
| iPhone, iPad | Streisand или V2Box |
| Windows, Mac | Hiddify |

В приложении нажмите «+» → «Сканировать QR-код». Или скопируйте ссылку `vless://…` и выберите «Импорт из буфера обмена».

## QR не сканируется?

Так бывает в веб-консоли хостера (маленький экран, нет нужных символов) или если вы устанавливали с того же телефона.

- `carry show` — показать QR ещё раз. В веб-консоли Carry уменьшает шрифт, чтобы код поместился целиком.
- `carry share` — **короткая временная ссылка** вида `http://1.2.3.4:23817/a1b2c3`. Её легко набрать вручную. Откройте её в браузере телефона и нажмите «Скопировать», либо добавьте в приложение как подписку. Ссылка живёт 15 минут или до Ctrl+C. Сама ссылка `vless://` по сети открытым текстом не передаётся.
- `cat /root/carry.txt` — все ссылки текстом.

## Команды

| Команда | Что делает |
|---|---|
| `carry show [имя]` | показать QR-код снова (`carry show имя hy2` — QR для Hysteria2) |
| `carry add <имя>` | ещё одно устройство или человек, у каждого свои ключи |
| `carry list` | список устройств |
| `carry remove <имя>` | отключить устройство |
| `carry share [имя]` | короткая временная ссылка |
| `carry uninstall` | удалить всё |

Имена пишутся латиницей: `mama`, `phone`, `laptop-2`.

## Параметры установки

| Параметр | Что делает |
|---|---|
| `--hy2` | добавить Hysteria2 на 443/udp (самоподписанный сертификат + obfs salamander) |
| `--no-hy2` | выключить Hysteria2 |
| `--sni сайт` | сайт, под который маскируется Reality. По умолчанию берётся первый рабочий из `www.samsung.com`, `www.nvidia.com`, `www.intel.com`, `www.oracle.com` |
| `--name имя` | имя первого устройства (по умолчанию `main`) |
| `--host адрес` | свой домен или IP вместо найденного автоматически |
| `--force` | запускать не на Ubuntu 22.04/24.04 (на свой риск) |

Повторный запуск безопасен. Ключи и устройства сохраняются, Xray и Hysteria2 обновляются, настройки перезаписываются начисто. Так же включается Hysteria2 позже: просто запустите команду ещё раз с `--hy2`.

## Что делает скрипт

- Ставит Xray-core **официальным скриптом** [XTLS/Xray-install](https://github.com/XTLS/Xray-install), а Hysteria2 официальным [get.hy2.sh](https://v2.hysteria.network/docs/getting-started/Server-Installation-Script/).
- Сам создаёт UUID, ключи x25519 и shortId. У каждого устройства свои UUID, shortId и пароль Hysteria2.
- VLESS + Reality, `flow: xtls-rprx-vision`, порт 443/tcp, отпечаток `chrome`.
- Сайт для маскировки проверяется прямо с сервера: Reality нужен TLS 1.3 и HTTP/2. `www.microsoft.com` и `www.apple.com` не используются по умолчанию, потому что Xray сам предупреждает, что с ними сервер чаще блокируют.
- Блокирует доступ через VPN к локальным сетям сервера и BitTorrent (чтобы хостер не получал жалоб).
- **ufw**: открыты SSH (22 и порт, на котором реально работает sshd), 443/tcp и, с `--hy2`, 443/udp.
- **BBR** и увеличенные UDP-буферы для Hysteria2.
- **unattended-upgrades**: автоматические обновления безопасности.
- Журнал всех действий: `/var/log/carry.log`. Состояние: `/etc/carry/`.

## Если что-то пошло не так

- Сообщения об ошибках написаны по-русски, рядом подсказка, что делать. Подробности в `/var/log/carry.log`.
- «Порт 443 занят»: на сервере уже работает веб-сервер или другой VPN. Возьмите чистый сервер или остановите ту программу.
- Не подключается: попробуйте другой сайт маскировки, например `--sni www.nvidia.com`, а потом заново отсканируйте QR. Если включён Hysteria2, попробуйте запасную ссылку.
- У некоторых хостеров есть свой файрвол в панели управления. Порт 443 (tcp и udp) должен быть открыт и там.

## Безопасность

- `/root/carry.txt` и `/etc/carry/` доступны только root. По ссылкам из них можно подключиться к серверу, так что не публикуйте их.
- У Hysteria2 самоподписанный сертификат, поэтому в ссылке стоит `insecure=1`. Это стандартная схема для личного сервера без домена. Основной протокол (Reality) от этого не зависит.

## Лицензия

[MIT](LICENSE)

---

<a id="english"></a>

# Carry (English)

**Your own VPN server with a single command.**

Carry turns a fresh Ubuntu VPS into a VLESS + Reality (Xray-core) server, optionally with Hysteria2 as a fallback. There is no web panel, so there is nothing to log into and nothing to break. At the end you get a QR code: scan it with your phone and you are connected.

## Install

1. Get a VPS running **Ubuntu 22.04 or 24.04** (the cheapest plan is fine, e.g. OVH).
2. Open the server console: your provider's web console (KVM), or SSH, including from a phone with Termius.
3. Paste one command:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/cookiefbi/carry/main/install.sh)
```

With the Hysteria2 fallback:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/cookiefbi/carry/main/install.sh) --hy2
```

It asks no questions. After 1–3 minutes you see a big "ГОТОВО" ("done"), a QR code and the links. Everything is also saved to `/root/carry.txt`. On-screen messages are in Russian.

## Which app to install

| Device | App |
|---|---|
| Android | v2rayNG or Hiddify |
| iPhone, iPad | Streisand or V2Box |
| Windows, Mac | Hiddify |

Tap "+" → "Scan QR code", or copy the `vless://…` link and use "Import from clipboard".

## QR code won't scan?

- `carry show` prints the QR code again. In a web KVM console it switches to a smaller font so the code fits on screen.
- `carry share` prints a **short temporary link** like `http://1.2.3.4:23817/a1b2c3` that is easy to type. Open it in the phone's browser and tap "Copy", or add it to the app as a subscription URL. It stays up for 15 minutes or until Ctrl+C. The `vless://` link itself never travels over the network in plain text.
- `cat /root/carry.txt` shows all links as text.

## Commands

| Command | What it does |
|---|---|
| `carry show [name]` | show the QR code again (`carry show name hy2` for Hysteria2) |
| `carry add <name>` | add another device or person, each with their own keys |
| `carry list` | list devices |
| `carry remove <name>` | revoke a device |
| `carry share [name]` | short temporary link |
| `carry uninstall` | remove everything |

## Install options

| Option | What it does |
|---|---|
| `--hy2` | add Hysteria2 on 443/udp (self-signed cert + salamander obfs) |
| `--no-hy2` | turn Hysteria2 off |
| `--sni site` | Reality camouflage site. The default is the first one that works from the server out of `www.samsung.com`, `www.nvidia.com`, `www.intel.com`, `www.oracle.com` |
| `--name name` | name of the first device (default `main`) |
| `--host addr` | your own domain or IP instead of the auto-detected one |
| `--force` | run on something other than Ubuntu 22.04/24.04 (at your own risk) |

Re-running is safe. Keys and devices are kept, Xray and Hysteria2 are upgraded, and the configs are rewritten from scratch. To add Hysteria2 later, just run the command again with `--hy2`.

## What it does

- Installs Xray-core with the **official** [XTLS/Xray-install](https://github.com/XTLS/Xray-install) script and Hysteria2 with the official [get.hy2.sh](https://v2.hysteria.network/docs/getting-started/Server-Installation-Script/).
- Generates the UUIDs, x25519 keys and shortIds. Each device gets its own UUID, shortId and Hysteria2 password.
- VLESS + Reality, `flow: xtls-rprx-vision`, port 443/tcp, `chrome` fingerprint.
- Checks the camouflage site from the server, since Reality needs TLS 1.3 and HTTP/2. `www.microsoft.com` and `www.apple.com` are not used by default because Xray itself warns that they raise the chance of the server getting blocked.
- Blocks access to the server's private networks and BitTorrent through the VPN.
- **ufw**: allows SSH (22 plus whatever port sshd actually listens on), 443/tcp, and 443/udp with `--hy2`.
- **BBR** plus larger UDP buffers for Hysteria2.
- **unattended-upgrades** for automatic security updates.
- Log: `/var/log/carry.log`. State: `/etc/carry/`.

## License

[MIT](LICENSE)
