#!/usr/bin/env bash
# Pure: inputs -> Playwright storageState JSON on stdout. No I/O, no globals.
# assemble_storage_state <db_jwt> <session_jwt> <app_origin> <now_epoch>
assemble_storage_state() {
  local db_jwt="$1" session_jwt="$2" app_origin="$3" now="$4"
  local host
  host="$(printf '%s' "$app_origin" | sed -E 's#^https?://##; s#/.*$##')"
  jq -n \
    --arg db "$db_jwt" \
    --arg sess "$session_jwt" \
    --arg host "$host" \
    --arg origin "$app_origin" \
    --argjson uat "$now" '
  {
    cookies: [
      {name:"__session",      value:$sess, domain:$host, path:"/", expires:-1, httpOnly:false, secure:true, sameSite:"Lax"},
      {name:"__clerk_db_jwt", value:$db,   domain:$host, path:"/", expires:-1, httpOnly:false, secure:true, sameSite:"Lax"},
      {name:"__client_uat",   value:($uat|tostring), domain:$host, path:"/", expires:-1, httpOnly:false, secure:true, sameSite:"Lax"}
    ],
    origins: [
      {origin:$origin, localStorage:[{name:"__clerk_db_jwt", value:$db}]}
    ]
  }'
}
