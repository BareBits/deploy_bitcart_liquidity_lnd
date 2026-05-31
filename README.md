# deploy_bitcart_liquidity_lnd

A shell script that deploys [Bitcart](https://bitcart.ai) (with the LND
wallet) plus the [Bitcart Liquidity Helper](https://github.com/BareBits/bitcart_liquidity)
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
export BITCART_SMTP_SERVER='mail.getbarebits.com'
export BITCART_SMTP_PORT='587'
export BITCART_SMTP_TLS='TRUE'
export BITCART_SMTP_SSL=''
export BITCART_SMTP_USERNAME='test@getbarebits.com'
export BITCART_SMTP_PASSWORD='somepassword'
export CASHOUT_LIGHTNING_ADDRESS='cashout@mywebsite.com'
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

The `BITCART_*` / `CASHOUT_LIGHTNING_ADDRESS` variables above are mapped to
`LIQUIDITYHELPER_*`-prefixed settings and written to
`compose/liquidityhelper.env` in the bitcart-docker checkout, which a
generated compose component loads into the backend + worker containers.
On a fresh install the plugin bootstraps the first Bitcart admin from
`ADMIN_EMAIL` / `ADMIN_PASSWORD`. Anything left unset can be edited later
in the plugin's **Settings** tab (plugin UI overrides win over env).

## Updates

A daily cron (`/etc/cron.d/bitcart_updates`) refreshes the plugin source
(commit-gated — it only re-syncs when the plugin repo actually moved) and
then runs bitcart-docker's `update.sh`, which rebuilds the plugin's backend
image and, only when its admin (Vue) files changed, the admin image
(`yarn build`).
