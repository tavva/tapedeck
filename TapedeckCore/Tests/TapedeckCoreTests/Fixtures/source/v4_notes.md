# Plaud 4.0 (workspace) API notes

Captured 2026-11-20 from web.plaud.ai and its JS bundle. All ids, names and
URLs in the fixtures are fake.

- Auth: `Authorization: Bearer <workspace token>`, plus `X-Scope-Type: workspace`
  and `X-Scope-Id: <workspace id>`. The web app always sends both; listing works
  without them, but we match the web app.
- The workspace token is a JWT carrying `region` (`aws:eu-central-1`) and `wid`
  (the workspace id).
- Most errors come back as HTTP 200 with a non-zero `status`. A bad token gives
  HTTP 401 with `unauthorised.json`. The old endpoints (`/file/simple/web`,
  `/file/temp-url/{id}`, `/file/list`) now return `account_migrated.json`.
- `GET /file-app/v4/recordings/all?page_size=N[&cursor=C]` returns
  `recordings_page*.json`. Paging is by cursor; the last page has
  `next_cursor: ""`. The list has no file size.
- On the wrong regional host, the same request returns `redirect_302.json`.
- `GET /file-app/v4/files/detail/{file_id}` returns `file_detail.json`. The
  `AUDIO` object's `content_url` is a presigned S3 link to the original audio and
  `object_size` is its size in bytes.
- File ids: recordings made before the migration are `of_<old 32-hex id>`; newer
  ones are `f_<hex>`. The detail endpoint needs the prefixed id.
- Refresh: `POST /user-app/auth/workspace/refresh/{workspace id}` with an empty
  body, `Authorization: Bearer <refresh token>` and the scope headers.
  `refresh_ok*.json` were built from the web bundle's response parser (token in
  `data.workspace_token`, else `data.access_token`; `refresh_token` and
  `refresh_expires_in` may be missing), not captured live.
