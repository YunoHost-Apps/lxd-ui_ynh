#!/bin/bash

#=================================================
# COMMON VARIABLES AND CUSTOM HELPERS
#=================================================

lxd_override="/etc/systemd/system/lxd.service.d/lxd-ui.conf"

# LXD serves the interface and its API itself, the app is useless without it
_check_lxd_is_installed() {
    if ! ynh_hide_warnings yunohost app info lxd > /dev/null 2>&1; then
        ynh_die "The 'lxd' app must be installed first, LXD is what serves this interface"
    fi
}

_build_ui() {
    local build_dir
    build_dir="$(mktemp -d)"

    ynh_setup_source --source_id="main" --dest_dir="$build_dir"

    pushd "$build_dir"
        export HOME="$build_dir"

        corepack enable
        ynh_hide_warnings corepack prepare yarn@1.22.22 --activate

        # The build reads the commit hash from git, and we build from a tarball
        git init --quiet .
        git -c user.email="$app@localhost" -c user.name="$app" \
            commit --quiet --allow-empty --message="$(ynh_app_upstream_version)"

        ynh_hide_warnings yarn install --frozen-lockfile
        ynh_hide_warnings yarn build
    popd

    # Emptied first, otherwise the minified files of the previous version pile up
    ynh_safe_rm "$install_dir"
    mkdir --parents "$install_dir"
    cp -a "$build_dir/build/ui/." "$install_dir/"
    chown -R "$app:$app" "$install_dir"
    chmod -R o-rwx "$install_dir"

    ynh_safe_rm "$build_dir"
}

# LXD reads LXD_UI at startup only, so it has to be restarted once for the
# interface to show up. That stops the running instances, hence PRE_INSTALL.md
_add_lxd_override() {
    mkdir --parents "$(dirname "$lxd_override")"
    ynh_config_add --template="systemd-override.conf" --destination="$lxd_override"
    systemctl daemon-reload

    # What the running daemon actually got, not what the unit now says
    local running_env="/proc/$(systemctl show lxd --property=MainPID --value)/environ"

    if ! grep --null-data --quiet --line-regexp --fixed-strings "LXD_UI=$install_dir" "$running_env"; then
        ynh_systemctl --service=lxd --action=restart
        lxd waitready --timeout=300
    fi
}

# No restart here: LXD keeps LXD_UI until it is restarted anyway, and it just
# serves its "UI is not available" page once the directory is gone
_remove_lxd_override() {
    if [ -e "$lxd_override" ]; then
        ynh_safe_rm "$lxd_override"
        systemctl daemon-reload
    fi
}

_add_client_certificate() {
    if [ ! -e "$data_dir/client.crt" ]; then
        ynh_hide_warnings openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -keyout "$data_dir/client.key" -out "$data_dir/client.crt" -subj "/CN=$app"
    fi

    # Read by the NGINX master process, which runs as root
    chown root:root "$data_dir/client.crt" "$data_dir/client.key"
    chmod 400 "$data_dir/client.crt" "$data_dir/client.key"

    local fingerprint
    fingerprint="$(openssl x509 -in "$data_dir/client.crt" -outform DER | sha256sum | cut --delimiter=' ' --fields=1)"
    ynh_app_setting_set --key=cert_fingerprint --value="$fingerprint"

    if ! lxc config trust show "$fingerprint" > /dev/null 2>&1; then
        lxc config trust add "$data_dir/client.crt"
    fi
}

_remove_client_certificate() {
    local fingerprint
    fingerprint="$(ynh_app_setting_get --key=cert_fingerprint)"

    if [ -n "$fingerprint" ] && lxc config trust show "$fingerprint" > /dev/null 2>&1; then
        lxc config trust remove "$fingerprint"
    fi
}

_set_lxd_https_address() {
    local previous
    previous="$(lxc config get core.https_address)"

    # Remember what LXD was listening on, to put it back when removing the app
    if [ "$previous" != "127.0.0.1:$port" ]; then
        ynh_app_setting_set --key=https_address_backup --value="$previous"
    fi

    lxc config set core.https_address "127.0.0.1:$port"
}

_restore_lxd_https_address() {
    local previous
    previous="$(ynh_app_setting_get --key=https_address_backup)"

    if [ -n "$previous" ]; then
        lxc config set core.https_address "$previous"
    else
        lxc config unset core.https_address
    fi
}
