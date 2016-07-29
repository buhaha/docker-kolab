#!/bin/bash

KOLAB_CONF=`          readlink -f "/etc/kolab/kolab.conf"`
ROUNDCUBE_CONF=`      readlink -f "/etc/roundcubemail/config.inc.php"`
PHP_CONF=`            readlink -f "/etc/php.ini"`
AMAVISD_CONF=`        readlink -f "/etc/amavisd/amavisd.conf"`
OPENDKIM_CONF=`       readlink -f "/etc/opendkim.conf"`
NGINX_CONF=`          readlink -f "/etc/nginx/nginx.conf"`
NGINX_KOLAB_CONF=`    readlink -f "/etc/nginx/conf.d/default.conf"`
HTTPD_CONF=`          readlink -f "/etc/httpd/conf/httpd.conf"`
HTTPD_SSL_CONF=`      readlink -f "/etc/httpd/conf.d/ssl.conf"`
IMAPD_CONF=`          readlink -f "/etc/imapd.conf"`

function chk_env {
    eval env="\$$1"
    val="${env:-$2}"
    if [ -z "$val" ]; then
        >&2 echo "chk_env: Enviroment vaiable \$$1 is not set."
        exit 1
    fi  
    export "$1"="$val"
}

function configure {
    local VARIABLE="$1"
    eval local STATE="\$$VARIABLE"
    local CHECKS="${@:2}"
    if [ -z $STATE ] ; then
        echo "configure: Skiping configure_${VARIABLE,,}, because \$$VARIABLE is not set"
        return 0
    fi
    if ! [ -z "$CHECKS" ] && ! [[ " ${CHECKS[@]} " =~ " ${STATE} " ]] ; then
        >&2 echo "configure: Unknown state $STATE for \$$VARIABLE (need: `echo $CHECKS | sed 's/ /|/g'`)"
        exit 1
    fi

    configure_${VARIABLE,,} ${STATE} || ( >&2 echo "configure: Error executing configure_${VARIABLE,,} ${STATE}" ; exit 1)
}

# Main functions

function setup_kolab {
    chk_env LDAP_ADMIN_PASS
    chk_env LDAP_MANAGER_PASS
    chk_env LDAP_CYRUS_PASS
    chk_env LDAP_KOLAB_PASS
    chk_env MYSQL_ROOT_PASS
    chk_env MYSQL_KOLAB_PASS
    chk_env MYSQL_ROUNDCUBE_PASS

    setup_kolab.exp

    # Redirect to /webmail/ in apache
    sed -i 's/^\(DocumentRoot \).*/\1"\/usr\/share\/roundcubemail\/public_html"/' $HTTPD_CONF
}

function configure_webserver {
    case $1 in
        nginx  ) 
            # Manage services
            export SERVICE_HTTPD=true
            export SERVICE_NGINX=false
            export SERVICE_PHP_FPM=false

            # Conigure Kolab for nginx
            crudini --set $KOLAB_CONF kolab_wap api_url "https://$(hostname -f)/kolab-webadmin/api"
            roundcube_conf --set $ROUNDCUBE_CONF assets_path "/assets/"
            roundcube_conf --set $ROUNDCUBE_CONF ssl_verify_peer false
            roundcube_conf --set $ROUNDCUBE_CONF ssl_verify_host false
        ;;
        apache )
            # Manage services
            export SERVICE_HTTPD=false
            export SERVICE_NGINX=true
            export SERVICE_PHP_FPM=true

            # Conigure Kolab for apache
            crudini --del $KOLAB_CONF kolab_wap api_url
            roundcube_conf --del $ROUNDCUBE_CONF assets_path
            roundcube_conf --del $ROUNDCUBE_CONF ssl_verify_peer
            roundcube_conf --del $ROUNDCUBE_CONF ssl_verify_host
        ;;
    esac
}

function configure_force_https {
    case $1 in
        true  ) 
            #TODO add section
        ;;
        false )
            #TODO add section
        ;;
    esac
}

function configure_nginx_cache {
    case $1 in
        true  ) 
            # Configure nginx cache
            if [ ! $(grep -q open_file_cache /etc/nginx/nginx.conf) ] ; then
                #Adding open file cache to nginx
                sed -i '/include \/etc\/nginx\/conf\.d\/\*.conf;/{
                a \    open_file_cache max=16384 inactive=5m;
                a \    open_file_cache_valid 90s; 
                a \    open_file_cache_min_uses 2;
                a \    open_file_cache_errors on;
                }' $NGINX_CONF

                sed -i '/include \/etc\/nginx\/conf\.d\/\*.conf;/{
                a \    fastcgi_cache_key "$scheme$request_method$host$request_uri";
                a \    fastcgi_cache_use_stale error timeout invalid_header http_500;
                a \    fastcgi_cache_valid 200 302 304 10m;
                a \    fastcgi_cache_valid 301 1h; 
                a \    fastcgi_cache_min_uses 2; 
                }' $NGINX_CONF

                sed -i '1ifastcgi_cache_path /var/lib/nginx/fastcgi/ levels=1:2 keys_zone=key-zone-name:16m max_size=256m inactive=1d;' $NGINX_KOLAB_CONF
                sed -i '/error_log/a \    fastcgi_cache key-zone-name;' $NGINX_KOLAB_CONF
            fi
        ;;
        false )
            # Configure nginx cache
            sed -i '/open_file_cache/d' $NGINX_CONF
            sed -i '/fastcgi_cache/d' $NGINX_CONF
            sed -i '/fastcgi_cache/d' $NGINX_KOLAB_CONF
        ;;
    esac
}

function configure_spam_sieve {
    case $1 in
        true  ) 
            # Manage services
            export SERVICE_SET_SPAM_SIEVE=true

            # Configure amavis
            sed -i '/^[^#]*$sa_spam_subject_tag/s/^/#/' $AMAVISD_CONF
            sed -i 's/^\($final_spam_destiny.*= \).*/\1D_PASS;/' $AMAVISD_CONF
            sed -r -i "s/^\\\$mydomain = '[^']*';/\\\$mydomain = '$(hostname -d)';/" $AMAVISD_CONF
        ;;
        false )
            # Manage services
            export SERVICE_SET_SPAM_SIEVE=false

            # Configure amavis
            sed -i '/^#i.*$sa_spam_subject_tag/s/^#//' $AMAVISD_CONF
            sed -i 's/^\($final_spam_destiny.*= \).*/\1D_DISCARD;/' $AMAVISD_CONF
        ;;
    esac
}

function configure_fail2ban {
    case $1 in
        true  ) 
            # Manage services
            export SERVICE_FAIL2BAN=true
       ;;
       false )
            # Manage services
            export SERVICE_FAIL2BAN=false
       ;;
    esac
}

function configure_dkim {
    case $1 in
        true  ) 
            # Manage services
            export SERVICE_OPENDKIM=true

            # Configure OpenDKIM
            if [ ! -f "/etc/opendkim/keys/$(hostname -s).private" ] 
                opendkim-genkey -D /etc/opendkim/keys/ -d $(hostname -d) -s $(hostname -s)
                chgrp opendkim /etc/opendkim/keys/*
                chmod g+r /etc/opendkim/keys/*
            fi
            
            #TODO Check this
            sed -i "/^127\.0\.0\.1\:[10025|10027].*smtpd/a \    -o receive_override_options=no_milters" /etc/postfix/master.cf

            opendkim_conf --set $OPENDKIM_CONF Mode sv
            opendkim_conf --set $OPENDKIM_CONF KeyTable "/etc/opendkim/KeyTable"
            opendkim_conf --set $OPENDKIM_CONF SigningTable "/etc/opendkim/SigningTable"
            opendkim_conf --set $OPENDKIM_CONF X-Header yes
        
            echo $(hostname -f | sed s/\\./._domainkey./) $(hostname -d):$(hostname -s):$(ls /etc/opendkim/keys/*.private) | cat > /etc/opendkim/KeyTable
            echo $(hostname -d) $(echo $(hostname -f) | sed s/\\./._domainkey./) | cat > /etc/opendkim/SigningTable
        
            postconf -e milter_default_action=accept
            postconf -e milter_protocol=2
            postconf -e smtpd_milters=inet:localhost:8891
            postconf -e non_smtpd_milters=inet:localhost:8891
        ;;
        false )
            # Manage services
            export SERVICE_OPENDKIM=false
        ;;
    esac
}

function configure_cert_path {
    if [ `find $CERT_PATH -prune -empty` ] ; then
        echo "configure_cert_path:  no certificates found in $CERT_PATH fallback to /etc/pki/tls/kolab"
        export CERT_PATH="/etc/pki/tls/kolab"
        local domain_cers=${CERT_PATH}/$(hostname -f)
    else
        local domain_cers=`ls -d ${CERT_PATH}/* | awk '{print $1}'`
    fi

    local certificate_path=${domain_cers}/cert.pem
    local privkey_path=${domain_cers}/privkey.pem
    local chain_path=${domain_cers}/chain.pem
    local fullchain_path=${domain_cers}/fullchain.pem

    if [ ! -f "$certificate_path" ] || [ ! -f "$privkey_path" ] ; then
        mkdir -p ${domain_cers}
        # Generate key and certificate
        openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
                    -subj "/CN=$(hostname -f)" \
                    -keyout $privkey_path \
                    -out $certificate_path
        # Set access rights
        chown -R root:mail ${domain_cers}
        chmod 750 ${domain_cers}
        chmod 640 ${domain_cers}/*
    fi
    
    # Configure apache for SSL
    sed -i -e "/[^#]SSLCertificateFile /c\SSLCertificateFile $certificate_path" $HTTPD_SSL_CONF
    sed -i -e "/[^#]SSLCertificateKeyFile /c\SSLCertificateKeyFile $privkey_path" $HTTPD_SSL_CONF
    if [ -f "$chain_path" ]; then
        if `sed 's/#.*$//g' /etc/httpd/conf.d/ssl.conf | grep -q SSLCertificateChainFile` ; then
            sed -e "/[^#]*SSLCertificateChainFile: /cSSLCertificateChainFile: $chain_path" $HTTPD_SSL_CONF
        else
            sed -i -e "/[^#]*SSLCertificateFile/aSSLCertificateChainFile: $chain_path" $HTTPD_SSL_CONF
        fi
    else
        sed -i -e "/SSLCertificateChainFile/d" $HTTPD_SSL_CONF
    fi
    
    # Configuration nginx for SSL
    if [ -f "$fullchain_path" ]; then
        sed -i -e "/ssl_certificate /c\    ssl_certificate $fullchain_path;" $NGINX_KOLAB_CONF
    else
        sed -i -e "/ssl_certificate /c\    ssl_certificate $certificate_path;" $NGINX_KOLAB_CONF
    fi
    sed -i -e "/ssl_certificate_key/c\    ssl_certificate_key $privkey_path;" $NGINX_KOLAB_CONF
    
    #Configure Cyrus for SSL
    sed -r -i --follow-symlinks \
        -e "s|^tls_server_cert:.*|tls_server_cert: $certificate_path|g" \
        -e "s|^tls_server_key:.*|tls_server_key: $privkey_path|g" \
        $IMAPD_CONF

    if [ -f "$chain_path" ]; then
        if grep -q tls_server_ca_file $IMAPD_CONF ; then
            sed -i --follow-symlinks -e "s|^tls_server_ca_file:.*|tls_server_ca_file: $chain_path|g" $IMAPD_CONF
        else
            sed -i --follow-symlinks -e "/tls_server_cert/atls_server_ca_file: $chain_path" $IMAPD_CONF
        fi
    else
        sed -i --follow-symlinks -e "/^tls_server_ca_file/d" $IMAPD_CONF
    fi
        
    #Configure Postfix for SSL
    postconf -e smtpd_tls_key_file=$privkey_path
    postconf -e smtpd_tls_cert_file=$certificate_path
    if [ -f "$chain_path" ]; then
        postconf -e smtpd_tls_CAfile=$chain_path
    else
        postconf -e smtpd_tls_CAfile=
    fi
}

function configure_kolab_default_locale {
    local $SIZE=$KOLAB_DEFAULT_QUOTA
    # Convert megabytes to bytes for kolab.conf
    case $SIZE in
    *"G" ) $SIZE=$[($(echo $SIZE | sed 's/[^0-9]//g'))*1024]
    *"M" ) $SIZE=$[($(echo $SIZE | sed 's/[^0-9]//g'))]
    *"K" ) $SIZE=$[($(echo $SIZE | sed 's/[^0-9]//g'))/1024]
    *    ) $SIZE=$[($(echo $SIZE | sed 's/[^0-9]//g'))/1024/1024]
    esac
    crudini --set $KOLAB_CONF kolab default_quota $SIZE
}

function configure_kolab_default_locale {
    crudini --set $KOLAB_CONF kolab default_locale "$KOLAB_DEFAULT_LOCALE"
}

function configure_max_memory_size {
    crudini --set $PHP_CONF php memory_limit $MAX_MEMORY_SIZE
}

function configure_max_file_size {
    crudini --set $PHP_CONF php upload_max_filesize $MAX_FILE_SIZE
}

function configure_max_mail_size {
    local $SIZE=$MAX_MAIL_SIZE
    # Convert megabytes to bytes for postfix
    case $SIZE in
    *"G" ) $SIZE=$[($(echo $SIZE | sed 's/[^0-9]//g'))*1024*1024*1024]
    *"M" ) $SIZE=$[($(echo $SIZE | sed 's/[^0-9]//g'))*1024*1024]
    *"K" ) $SIZE=$[($(echo $SIZE | sed 's/[^0-9]//g'))*1024]
    *    ) $SIZE=$[($(echo $SIZE | sed 's/[^0-9]//g'))]
    esac
    postconf -e message_size_limit=$SIZE
}

function configure_max_mailbox_size {
    local $SIZE=$MAX_MAILBOX_SIZE
    # Convert megabytes to bytes for postfix
    case $SIZE in
    *"G" ) $SIZE=$[($(echo $SIZE | sed 's/[^0-9]//g'))*1024*1024*1024]
    *"M" ) $SIZE=$[($(echo $SIZE | sed 's/[^0-9]//g'))*1024*1024]
    *"K" ) $SIZE=$[($(echo $SIZE | sed 's/[^0-9]//g'))*1024]
    *    ) $SIZE=$[($(echo $SIZE | sed 's/[^0-9]//g'))]
    esac
    postconf -e mailbox_size_limit=$MAX_MAILBOX_SIZE
}

function configure_max_body_size {
    sed -i -e '/client_max_body_size/c\        client_max_body_size '$MAX_BODY_SIZE';' $NGINX_KOLAB_CONF
}

function configure_roundcube_skin {
    roundcube_conf --set $ROUNDCUBE_CONF skin $ROUNDCUBE_SKIN
}

function configure_roundcube_trash {
    case $1 in
        trash )
            roundcube_conf --set $ROUNDCUBE_CONF skip_deleted false
            roundcube_conf --set $ROUNDCUBE_CONF flag_for_deletion false
        ;;
        flag )
            roundcube_conf --set $ROUNDCUBE_CONF skip_deleted true
            roundcube_conf --set $ROUNDCUBE_CONF flag_for_deletion true
        ;;
        esac
}


function configure_ext_milter_addr {
    if [ ! -z $1 ] ; then
        # Manage services
        export SERVICE_AMAVISD=false
        export SERVICE_CLAMD=false

        # Conigure Postfix for external milter
        #TODO add section
    else
        # Conigure Postfix for external milter
        #TODO add section
    fi
}

function configure_roundcube_plugins {
    local roundcube_plugins=($(env | grep -oP '(?<=^ROUNDCUBE_PLUGIN_)[a-zA-Z0-9_]*'))
    for plugin_var in ${roundcube_plugins[@]} ; do
        local plugin_dir="/usr/share/roundcubemail/plugins"
        local plugin_mask=$(echo $plugin_var | sed 's/_/.?/g')
        local plugin_name=$(ls $plugin_dir -1 | grep -iE "^$plugin_mask$")
        eval local plugin_state=\$ROUNDCUBE_PLUGIN_${plugin_var}

        if $(echo $plugin_name | grep -q ' '); then
            >&2 echo "configure_roundcube_plugins: Duplicate roundcube plugins: $(echo $plugin_name)"
            exit 1
        elif [ -z "$plugin_name" ]; then
            >&2 echo "configure_roundcube_plugins:  Roundcube plugin ${plugin_var,,} not found in $plugin_dir"
            exit 1
        elif ! ( [ "$plugin_state" == true ] || [ "$plugin_state" == false ] ); then
            >&2 echo "configure_roundcube_plugins: Unknown state $plugin_state for roundcube plugin ${plugin_name} (need: true|false)"
            exit 1
        fi

        configure_roundcube_plugin $plugin_name $plugin_state
    done
}

# Addition functions

function configure_roundcube_plugin {
    local PLUGIN=$1
    local STATE=$2
    case $STATE in
        true  )
            #TODO add section
        ;;
        false )
            #TODO add section
        ;;
    esac
}

function roundcube_conf {
    local ACTION="$1"
    local FILE="$2"
    local OPTION="$3"
    local VALUE="$4"

    case $ACTION in
        --set )
            if [ -z $(roundcube_conf --get "$FILE" "$OPTION") ]; then
                echo "\$config['$3'] = '$4';" >> "$2"
            else
                sed -i -r "s|^\\s*(\\\$config\\[['\"]$OPTION['\"]\\])\\s*=[^;]*;|\\1 = '$VALUE';|g" "$FILE"
            fi
        ;;
        --get )
            cat "$FILE" | grep -oP '(?<=\$config\['\'"$OPTION"\''\] = '\'').*(?='\'';)' | sed -r -e 's|^[^'\'']*'\''||g' -e 's|'\''.*$||'
        ;;
        --del )
            sed -i -r "/^\\s*(\\\$config\\[['\"]$OPTION['\"]\\])\\s*=[^;]*;/d" "$FILE"
    esac
}

function opendkim_conf {
    local ACTION="$1"
    local FILE="$2"
    local OPTION="$3"
    local VALUE="$4"

    case $ACTION in
        --set )
            sed -i '1{p;s|.*|'$OPTION' '"$VALUE"'|;h;d;};/^'$OPTION'/{g;p;s|.*||;h;d;};$G' $FILE
        ;;
    esac
}
