# fluent-plugin-oceanbase-logs

Fluentd input plugin that periodically fetches SQL diagnostics data from [OceanBase Cloud](https://www.oceanbase.com/). Each event is one SQL execution (sample), with deduplication by `traceId`.

| `log_type` | API Path | Description |
| --- | --- | --- |
| `slow_sql` (default) | `/api/v2/.../slowSql` + samples | Slow SQL (per-execution) |
| `top_sql` | `/api/v2/.../topSql` + samples | Top SQL (per-execution) |

## Requirements

| fluent-plugin-oceanbase-logs | fluentd   | ruby   |
| ---------------------------- | --------- | ------ |
| >= 0.1.2                    | >= 1.8.0  | >= 2.4 |

## Installation

```bash
gem install fluent-plugin-oceanbase-logs
```

## Preparation

1. Create an AccessKey pair at [OceanBase Cloud AccessKey Management](https://console-cn.oceanbase.com/account/accessKey)
2. Find your **Instance ID** and **Tenant ID** from the OceanBase Cloud console

## Configuration

### Slow SQL → file

```xml
<source>
  @type oceanbase_logs
  tag  oceanbase.slow_sql
  log_type slow_sql

  access_key_id     "#{ENV['OCEANBASE_ACCESS_KEY_ID']}"
  access_key_secret "#{ENV['OCEANBASE_ACCESS_KEY_SECRET']}"
  instance_id       "#{ENV['OCEANBASE_INSTANCE_ID']}"
  tenant_id         "#{ENV['OCEANBASE_TENANT_ID']}"

  # API endpoint
  endpoint          api-cloud-cn.oceanbase.com
  # Fetch interval (seconds) and lookback window (seconds)
  fetch_interval    60
  lookback_seconds  600

  deduplicate       true

  <storage>
    @type local
    persistent true
    path /var/log/fluentd/slow_sql_seen
  </storage>
</source>

<match oceanbase.slow_sql>
  @type file
  path /var/log/fluentd/slow_sql
  append true
  <format>
    @type json
  </format>
  <buffer>
    @type file
    path /var/log/fluentd/buffer/slow_sql
    flush_mode interval
    flush_interval 5s
  </buffer>
</match>
```

### Slow SQL → Loki

Requires [fluent-plugin-grafana-loki](https://github.com/grafana/fluent-plugin-grafana-loki). Example: Slow SQL to Grafana Loki.

```xml
<source>
  @type oceanbase_logs
  tag  oceanbase.slow_sql
  log_type slow_sql

  access_key_id     "#{ENV['OCEANBASE_ACCESS_KEY_ID']}"
  access_key_secret "#{ENV['OCEANBASE_ACCESS_KEY_SECRET']}"
  instance_id       "#{ENV['OCEANBASE_INSTANCE_ID']}"
  tenant_id         "#{ENV['OCEANBASE_TENANT_ID']}"

  endpoint          api-cloud-cn.oceanbase.com
  fetch_interval    60
  lookback_seconds  600

  deduplicate       true
  include_metadata  true

  <storage>
    @type local
    persistent true
    path /var/log/fluentd/oceanbase_slow_sql.state
  </storage>
</source>

<filter oceanbase.slow_sql>
  @type record_transformer
  enable_ruby true
  <record>
    message ${record["sqlTextShort"]}
  </record>
</filter>

<match oceanbase.slow_sql>
  @type loki
  url http://localhost:3100

  extra_labels {"job":"oceanbase-slow-sql"}

  <label>
    ob_instance_id
    ob_tenant_id
    dbName
    sqlType
    userName
  </label>

  remove_keys ob_log_type

  <buffer>
    @type memory
    flush_interval 10s
    chunk_limit_size 1m
    retry_max_interval 30s
    retry_forever true
  </buffer>
</match>
```

### Parameters

#### Core

| Parameter | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `log_type` | enum | no | `slow_sql` | `slow_sql` or `top_sql` |
| `tag` | string | **yes** | — | Fluentd tag for emitted events |

#### Authentication

| Parameter | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `access_key_id` | string | **yes** | — | OceanBase Cloud AccessKey ID |
| `access_key_secret` | string | **yes** | — | OceanBase Cloud AccessKey Secret |

#### Cluster

| Parameter | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `instance_id` | string | **yes** | — | OceanBase cluster instance ID |
| `tenant_id` | string | **yes** | — | OceanBase tenant ID |
| `project_id` | string | no | nil | Project ID (`X-Ob-Project-Id` header) |

#### Filters

| Parameter | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `db_name` | string | no | nil | Filter by database name |
| `search_keyword` | string | no | nil | Search keyword in SQL text |
| `node_ip` | string | no | nil | Database node IP |
| `filter_condition` | string | no | nil | Advanced filter (e.g. `@avgCpuTime > 20`) |
| `sql_text_length` | integer | no | 65535 | Max SQL text length returned |

#### Endpoint and fetch timing (configured in config file)

| Parameter | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `endpoint` | string | no | `api-cloud-cn.oceanbase.com` | API endpoint (use `api-cloud.oceanbase.com` for international) |
| `fetch_interval` | time | no | 300 (5 min) | Fetch interval (seconds): how often to call the API |
| `lookback_seconds` | integer | no | 600 (10 min) | Lookback window (seconds): time range of data to query per request |

Can be overridden by environment variables: `OCEANBASE_ENDPOINT`, `OCEANBASE_FETCH_INTERVAL`, `OCEANBASE_LOOKBACK_SECONDS` (see `example/` and `.env.example`).

#### Behaviour

| Parameter | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `deduplicate` | bool | no | true | Skip already-seen records (by traceId) |
| `include_metadata` | bool | no | true | Attach `ob_instance_id` / `ob_tenant_id` / `ob_log_type` to records |
| `ssl_verify_peer` | bool | no | true | Verify SSL certificates |
| `http_proxy` | string | no | nil | HTTP proxy URL |

(`endpoint` is in the "Endpoint and fetch timing" table above.)

## Output record fields

Each record is one SQL execution (sample). Main fields:

| Field | Type | Description |
| --- | --- | --- |
| `sqlId` | string | SQL identifier |
| `fullSqlText` | string | Complete SQL text |
| `sqlTextShort` | string | SQL text (truncated) |
| `sqlType` | string | `SELECT`, `UPDATE`, etc. |
| `dbName` | string | Database name |
| `userName` | string | User |
| `requestTime` | string | Execution timestamp (UTC) |
| `traceId` | string | Unique trace ID (used for dedup) |
| `elapsedTime` | double | Response time (ms) |
| `cpuTime` | double | CPU time (ms) |
| `executeTime` | double | Plan execution time (ms) |
| `returnRows` | long | Returned rows |
| `affectedRows` | long | Affected rows |

## Examples

See the `example/` directory:

- `fluentd.conf` — Slow SQL to file
- `fluentd_to_file.conf` — Slow SQL + Top SQL to file
- `fluentd_to_loki.conf` — Slow SQL + Top SQL to Grafana Loki

## Test

```bash
fluentd -c /fluentd/etc/fluentd.conf
```

## License

Apache License Version 2.0, January 2004 — [http://www.apache.org/licenses/](http://www.apache.org/licenses/LICENSE-2.0)
