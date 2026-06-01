# deploy_bitcart_liquidity_lnd

A shell script that deploys [Bitcart](https://bitcart.ai) (with the LND
wallet) plus the [Bitcart Liquidity Helper](https://github.com/BareBits/bitcart_liquidity_lnd)
**as a Bitcart plugin** to a fresh bare-metal server or VPS, in one command.

The liquidity helper runs *inside* Bitcart (it is no longer a standalone
systemd service). Its admin UI appears under **Plugins → liquidityhelper**,
and it manages an LND (`btclnd`) wallet per store automatically.

## One-line install

Set the variables, then run the bootstrap. `BRANCH` selects the release
channel across all BareBits forks: `main` (default) or `testing`. A
`testing` branch is used on each fork only where it exists; otherwise that
fork falls back to its default branch — so `testing` works even before
every repo has the branch.

```bash
#export BTCLND_NETWORK=signet
export BTCLND_DEBUG=true
export BITCART_HOST='somehost.com'
export BITCART_ADMIN_EMAIL='office@somehost.com'
# no quote characters allowed
export BITCART_ADMIN_PASSWORD='mybhjhgffd789!!'
export LIQUIDITYHELPER_SMTP_SERVER='mail.getbarebits.com'
export LIQUIDITYHELPER_SMTP_PORT='587'
export LIQUIDITYHELPER_SMTP_TLS='TRUE'
export LIQUIDITYHELPER_SMTP_SSL=''
export LIQUIDITYHELPER_SMTP_USERNAME='test@getbarebits.com'
export LIQUIDITYHELPER_SMTP_PASSWORD='somepassword'
export CASHOUT_LIGHTNING_ADDRESS='cashout@mywebsite.com'
# Liquidity management mode. These two enable AUTOMATIC channel
# management. Omit both to leave liquidity management disabled (the repo
# default) and pick a mode later in the plugin's dashboard. Any
# LIQUIDITYHELPER_*-prefixed var here is forwarded as a plugin setting.
export LIQUIDITYHELPER_LIQUIDITY_DISABLED='False'
export LIQUIDITYHELPER_AUTOMATIC_CHANNEL_CREATION_ENABLED='True'
export BRANCH='main'
cd /opt; apt install -yy git \
  && { git clone -b "$BRANCH" https://github.com/BareBits/deploy_bitcart_liquidity_lnd.git \
       || git clone https://github.com/BareBits/deploy_bitcart_liquidity_lnd.git; } \
  && cd deploy_bitcart_liquidity_lnd \
  && { git checkout "$BRANCH" 2>/dev/null || true; } \
  && chmod +x deploy.sh && ./deploy.sh
```

The `git clone -b "$BRANCH"` falls back to a default clone (then an
opportunistic `git checkout "$BRANCH"`) so the command still works when the
deploy repo has no `testing` branch yet.

## How config reaches the plugin

Plugin settings are written to `compose/liquidityhelper.env` in the
bitcart-docker checkout, which a generated compose component loads into the
backend + worker containers. `BITCART_ADMIN_EMAIL` / `BITCART_ADMIN_PASSWORD`
and `CASHOUT_LIGHTNING_ADDRESS` are mapped to their `LIQUIDITYHELPER_*`
settings (and the SMTP notification From/To default to the admin email); on
a fresh install the plugin bootstraps the first Bitcart admin from those
credentials. Everything else — SMTP, liquidity mode, etc. — is set by
exporting the `LIQUIDITYHELPER_*` var directly (see below). Anything left
unset can be edited later in the plugin's **Settings** tab (plugin UI
overrides win over env).

In addition, **any `LIQUIDITYHELPER_*`-prefixed environment variable** you
export is forwarded verbatim into that env file, so you can set *any*
plugin setting at deploy time — e.g. the liquidity mode shown in the
single-line command above. The deploy script itself sets no mode, so
running it without those vars leaves liquidity management **disabled** (the
plugin is installed but idle); the single-line command opts into automatic
channel management via `LIQUIDITYHELPER_LIQUIDITY_DISABLED=False` +
`LIQUIDITYHELPER_AUTOMATIC_CHANNEL_CREATION_ENABLED=True`.

## Updates

A daily cron (`/etc/cron.d/bitcart_updates`) refreshes the plugin source
(commit-gated — it only re-syncs when the plugin repo actually moved) and
then runs bitcart-docker's `update.sh`, which rebuilds the plugin's backend
image and, only when its admin (Vue) files changed, the admin image
(`yarn build`).
