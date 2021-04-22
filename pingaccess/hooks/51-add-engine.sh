#!/usr/bin/env sh
#
# Ping Identity DevOps - Docker Build Hooks
#
#- This script is started in the background immediately before
#- the server within the container is started
#-
#- This is useful to implement any logic that needs to occur after the
#- server is up and running
#-
#- For example, enabling replication in PingDirectory, initializing Sync
#- Pipes in PingDataSync or issuing admin API calls to PingFederate or PingAccess

# shellcheck source=../../../../pingcommon/opt/staging/hooks/pingcommon.lib.sh
. "${HOOKS_DIR}/pingcommon.lib.sh"

_out="/tmp/pa.api.request.out"
_configzip="/tmp/engine-config.zip"
_pahost=${PA_CONSOLE_HOST}
_paport=${PA_ADMIN_PORT}
_password=${PING_IDENTITY_PASSWORD:-PA_ADMIN_PASSWORD_INITIAL}
# The environment variables PA_ADMIN_PRIVATE_ and PA_ADMIN_PUBLIC_... are automatically created from
# ping-devops helm charts
test -n "${PA_ADMIN_PRIVATE_HOSTNAME}" && _pahost=${PA_ADMIN_PRIVATE_HOSTNAME}
test -n "${PA_ADMIN_PRIVATE_PORT_HTTPS}" && _paport=${PA_ADMIN_PRIVATE_PORT_HTTPS}
## Specific to the multi region deployment, using the public console ingress
test -n "${PA_ADMIN_PUBLIC_HOSTNAME}" && _pahost=${PA_ADMIN_PUBLIC_HOSTNAME}
test -n "${PA_ADMIN_PUBLIC_PORT_HTTPS}" && _paport=${PA_ADMIN_PUBLIC_PORT_HTTPS}

_pa_curl ()
{
     _curl \
        --insecure \
        --user "${ROOT_USER}:${_password}" \
        --header "X-Xsrf-Header: PingAccess" \
        --output ${_out} \
        "${@}"
    return ${?}
}

if test -n "${OPERATIONAL_MODE}" && test "${OPERATIONAL_MODE}" = "CLUSTERED_ENGINE"
then
    echo "This node is an engine..."
    echo "Checking admin heartbeat: https://${_pahost}:${_paport}/pa/heartbeat.ping"

    while true
    do
        _pa_curl "https://${_pahost}:${_paport}/pa/heartbeat.ping" 2>/dev/null
        if test $? -ne 0 ;
        then
            echo "Adding Engine: Server not started, waiting.."
            sleep 10
        else
            echo "PA started, begin adding engine"
            break
        fi
    done

    _basePaURL="https://${_pahost}:${_paport}/pa-admin-api/v3"
    _userURL="${_basePaURL}/users/1"
    _httpsListenersURL="${_basePaURL}/httpsListeners"
    _keyPairsURL="${_basePaURL}/keyPairs"
    _certsURL="${_basePaURL}/certificates"
    _enginesURL="${_basePaURL}/engines"


    _pa_curl \
        "${_userURL}" \
        2>/dev/null \
    || die_on_error 51 "Connection to admin (${_userURL})unsuccessful. Check vars PA_ADMIN_PUBLIC_HOSTNAME, PA_ADMIN_PUBLIC_PORT_HTTPS, ROOT_USER and PING_IDENTITY_PASSWORD"

    # Get Engine Certificate ID
    echo "Retrieving Key Pair ID from administration API..."
    _pa_curl "${_httpsListenersURL}"
    test ${?} -ne 200 && die_on_error 51 "Could not retrieve key-pair ID using ${_httpsListenersURL}"
    keypairid=$( jq -r '.items[] | select(.name=="CONFIG QUERY") | .keyPairId' "${_out}" )
    echo "KeyPairId: ${keypairid}"

    # Get KeyPair Alias
    echo "Retrieving the Key Pair alias..."
    _pa_curl "${_keyPairsURL}"
    test ${?} -ne 200 && die_on_error 51 "Could not retrieve key-pair alias using ${_keyPairsURL}"
    kpalias=$( jq -r '.items[] | select(.id=='${keypairid}') | .alias' "${_out}" )
    echo "Key Pair Alias: ${kpalias}"

    # Get Certificate ID
    echo "Retrieving Engine Certificate ID..."
    _pa_curl  "${_certsURL}"
    test ${?} -ne 200 && die_on_error 51 "Could not retrieve certificate ID using ${_certsURL}"
    # Escaped double-quotes are used below to handle aliases that contain spaces
    certid=$( jq -r ".items[] | select(.alias==\"${kpalias}\" and .keyPair==true) | .id" "${_out}" )
    echo "Engine Cert ID: ${certid}"

    host=$( hostname )
    echo "Adding new engine: ${host}"
    engineid=$(
        curl \
            --insecure \
            --request POST \
            --user "${ROOT_USER}:${_password}" \
            --header "X-Xsrf-Header: PingAccess" \
            --data '{"name":"'"${host}"'", "selectedCertificateId": "'"${certid}"'"}' \
            "${_enginesURL}" | jq -r '.id' )

    echo "EngineId: ${engineid}"
    echo "Retrieving the engine config..."
    curl \
        --insecure \
        --request POST \
        --user "${ROOT_USER}:${_password}" \
        --header "X-Xsrf-Header: PingAccess" \
        --output "${_configzip}" \
        "${_enginesURL}/${engineid}/config"

    echo "Extracting bootstrap and pa.jwk files to conf folder..."
    unzip -o "${_configzip}" -d "${OUT_DIR}/instance"
    # ls -la ${OUT_DIR}instance/conf
    # cat ${OUT_DIR}/instance/conf/bootstrap.properties
    chmod 400 "${OUT_DIR}/instance/conf/pa.jwk"

    echo "Cleanup zip.."
    rm "${_configzip}"
    rm "${_out}"
fi
