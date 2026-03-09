# fluent-plugin-oceanbase-logs

Fluentd input plugin that periodically fetches SQL diagnostics data from [OceanBase Cloud](https://www.oceanbase.com/). Each event is one SQL execution (sample), with deduplication by `traceId`.

| `log_type` | API Path | Description |
| --- | --- | --- |
| `slow_sql` (default) | `/api/v2/.../slowSql` + samples | Slow SQL (per-execution) |
| `top_sql` | `/api/v2/.../topSql` + samples | Top SQL (per-execution) |

## Requirements

| fluent-plugin-oceanbase-logs | fluentd   | ruby   |
| ---------------------------- | --------- | ------ |
| >= 0.1.0                     | >= 1.8.0  | >= 2.4 |

## Installation

```bash
gem install fluent-plugin-oceanbase-logs
```

## Preparation

1. Create an AccessKey pair at [OceanBase Cloud AccessKey Management](https://console-cn.oceanbase.com/account/accessKey)
2. Find your **Instance ID** and **Tenant ID** from the OceanBase Cloud console

## Configuration

### Slow SQL → file (one record per execution)

```xml
<source>
  @type oceanbase_logs
  tag  oceanbase.slow_sql
  log_type slow_sql

  access_key_id     "#{ENV['OCEANBASE_ACCESS_KEY_ID']}"
  access_key_secret "#{ENV['OCEANBASE_ACCESS_KEY_SECRET']}"
  instance_id       "#{ENV['OCEANBASE_INSTANCE_ID']}"
  tenant_id         "#{ENV['OCEANBASE_TENANT_ID']}"

  # 服务接入点（API 地址）
  endpoint          api-cloud-cn.oceanbase.com
  # 采集间隔（秒）与采集时间范围（秒）
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

#### 服务接入点与采集时间（均在配置文件中配置）

| Parameter | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `endpoint` | string | no | `api-cloud-cn.oceanbase.com` | 服务接入点（API 地址；国际站可用 `api-cloud.oceanbase.com`） |
| `fetch_interval` | time | no | 300 (5 min) | 采集间隔（秒）：每隔多久请求一次 API |
| `lookback_seconds` | integer | no | 600 (10 min) | 采集时间范围（秒）：每次请求查询最近多长时间的数据 |

可通过环境变量覆盖：`OCEANBASE_ENDPOINT`、`OCEANBASE_FETCH_INTERVAL`、`OCEANBASE_LOOKBACK_SECONDS`（参见 `example/` 与 `.env.example`）。

#### Behaviour

| Parameter | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `deduplicate` | bool | no | true | Skip already-seen records (by traceId) |
| `include_metadata` | bool | no | true | Attach `ob_instance_id` / `ob_tenant_id` / `ob_log_type` to records |
| `ssl_verify_peer` | bool | no | true | Verify SSL certificates |
| `http_proxy` | string | no | nil | HTTP proxy URL |

（`endpoint` 见上表「服务接入点与采集时间」。）

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
bundle install
bundle exec rake test
```

## License

MIT
