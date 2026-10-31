# CloudWatch Logs Insights クエリ集

コンソール: CloudWatch → Logs Insights → ロググループを選択 → 期間を観測期間（48h）に合わせて実行。
クエリは「保存（Save）」しておくと記事用スクショ・再実行が楽。料金はスキャン量 $0.0076/GB（東京）程度で、今回の規模ならほぼ0円。

> 自分の確認用アクセスを除外するため、構築直後に `curl https://checkip.amazonaws.com` で自宅のグローバルIPを控えておき、
> 各クエリに `| filter client_ip != "x.x.x.x"`（WAF は `httpRequest.clientIp`）を足す。

---

## A. nginx アクセスログ（`/honeypot/nginx/access`）

nginx は JSON で出力しているので `client_ip` `uri` `user_agent` `status` などが自動でフィールドになる。
※ WAF が BLOCK したリクエストは nginx に届かないので、ここには「WAFを通過したもの」だけが残る。

### A-1. 概要（総数・ユニークIP・ユニークURI）
```
stats count(*) as requests, count_distinct(client_ip) as unique_ips, count_distinct(uri) as unique_uris
```

### A-2. Top IP
```
stats count(*) as hits by client_ip
| sort hits desc
| limit 20
```

### A-3. Top Request URI
```
stats count(*) as hits by uri
| sort hits desc
| limit 50
```

### A-4. Top User-Agent
```
stats count(*) as hits by user_agent
| sort hits desc
| limit 30
```

### A-5. 時系列（1時間ごと）
```
stats count(*) as hits by bin(1h)
| sort @timestamp asc
```

### A-6. ステータス・メソッド分布
```
stats count(*) as hits by status, method
| sort hits desc
```

### A-7. 既知の攻撃パス（計画書の例 + よく来るもの）
```
filter uri like /(?i)(wp-login\.php|wp-admin|xmlrpc\.php|wp-content|wp-includes|\/\.env|\/\.git\/|phpmyadmin|\/pma\/|cgi-bin|vendor\/phpunit|eval-stdin\.php|boaform|HNAP1|GponForm|setup\.cgi|\/actuator|\/solr|\/\.aws|\/config\.json|\/server-status|\/console|\/manager\/html|\/owa\/|\/autodiscover)/
| stats count(*) as hits, count_distinct(client_ip) as ips by uri
| sort hits desc
| limit 100
```

### A-8. 攻撃カテゴリ別の件数（カテゴリごとに filter を差し替えて実行）
| カテゴリ | filter |
|---|---|
| WordPress | `filter uri like /(?i)(wp-|xmlrpc)/` |
| 機密ファイル探索 | `filter uri like /(?i)(\.env|\.git|\.aws|\.ssh|\.DS_Store|config\.(php|json|yml)|backup|\.sql|\.zip)/` |
| phpMyAdmin / DB管理 | `filter uri like /(?i)(phpmyadmin|pma|adminer|mysql)/` |
| CGI / IoT機器 | `filter uri like /(?i)(cgi-bin|boaform|HNAP1|GponForm|setup\.cgi|goform)/` |
| PHPUnit RCE | `filter uri like /(?i)phpunit/` |
| パストラバーサル | `filter uri like /(\.\.\/|\.\.%2f|%2e%2e)/` |
| コマンド注入っぽい | `filter uri like /(?i)(cmd=|exec=|wget|curl|\bsh\b|bash|%3B|%7C|\$\()/` |
| Log4Shell 系 | `filter uri like /(?i)(\$\{jndi|%24%7Bjndi)/ or user_agent like /(?i)\$\{jndi/` |

最後に `| stats count(*) as hits, count_distinct(client_ip) as ips` を付ける。

### A-9. Bot / ツールの判定（UA に含まれる単語で分類。大文字小文字違いは別行になるので集計時に合算）
```
parse user_agent /(?i)(?<tool>googlebot|bingbot|censys|shodan|zgrab|masscan|nmap|nuclei|zmap|expanse|internetmeasurement|paloalto|l9explore|curl|wget|python-requests|python|go-http-client|okhttp|libwww|java|bot|crawler|spider|scan)/
| stats count(*) as hits by tool
| sort hits desc
```
Bot 割合は「上の合計 + UA空」÷ A-1 の総数で出す。UA が空のリクエスト数：
```
filter isempty(user_agent) or user_agent = "-"
| stats count(*) as empty_ua
```

### A-10. 1つのIPが何をしたか（Top IP を深掘り）
```
filter client_ip = "x.x.x.x"
| fields @timestamp, method, uri, status, user_agent
| sort @timestamp asc
| limit 200
```

### A-11. Host ヘッダ（IP直打ちか、ALBのDNS名か、偽装か）
```
stats count(*) as hits by host
| sort hits desc
```

---

## B. nginx エラーログ（`/honeypot/nginx/error`）
```
fields @timestamp, @message
| sort @timestamp desc
| limit 100
```

---

## C. WAF ログ（`aws-waf-logs-honeypot`）

WAF ログには BLOCK/ALLOW 両方が残る。主なフィールド: `action`, `terminatingRuleId`, `httpRequest.clientIp`,
`httpRequest.country`, `httpRequest.uri`, `httpRequest.args`, `httpRequest.httpMethod`。
国別分析は ALB ログには国情報が無いので、この WAF ログの `httpRequest.country` を使う。

### C-1. ALLOW / BLOCK の割合
```
stats count(*) as hits by action
```

### C-2. 検知ルールランキング（ルールグループ単位）
```
filter action = "BLOCK"
| stats count(*) as hits by terminatingRuleId
| sort hits desc
```

### C-3. 検知ルールランキング（グループ内の個別ルール単位）
個別ルール名はネストした配列にあるので正規表現で抜く。COUNT モード時もこれで拾える。
```
parse @message /"terminatingRule":\{"ruleId":"(?<sub_rule>[^"]+)"/
| filter ispresent(sub_rule)
| stats count(*) as hits by sub_rule, action
| sort hits desc
```

### C-4. Block 理由のサンプル（記事用）
```
parse @message /"terminatingRule":\{"ruleId":"(?<sub_rule>[^"]+)"/
| filter action = "BLOCK"
| fields @timestamp, httpRequest.clientIp, httpRequest.country, httpRequest.httpMethod, httpRequest.uri, httpRequest.args, terminatingRuleId, sub_rule
| sort @timestamp desc
| limit 50
```

### C-5. 国別
```
stats count(*) as hits, count_distinct(httpRequest.clientIp) as ips by httpRequest.country
| sort hits desc
| limit 30
```

### C-6. 国別 × アクション
```
stats count(*) as hits by httpRequest.country, action
| sort hits desc
| limit 50
```

### C-7. Top IP（WAF 視点・BLOCK 含む全リクエスト）
```
stats count(*) as hits by httpRequest.clientIp, httpRequest.country, action
| sort hits desc
| limit 20
```

### C-8. WAF ログから User-Agent を取り出す
ヘッダは `[{"name":..,"value":..}]` の配列なので parse で抜く。
```
parse @message /"name":"[Uu]ser-[Aa]gent","value":"(?<ua>[^"]*)"/
| stats count(*) as hits by ua, action
| sort hits desc
| limit 30
```

### C-9. 時系列（アクション別）
```
stats count(*) as hits by bin(1h), action
| sort @timestamp asc
```

### C-10. BLOCK された URI ランキング
```
filter action = "BLOCK"
| stats count(*) as hits by httpRequest.uri
| sort hits desc
| limit 50
```

---

## D. ALB アクセスログ（S3）について
ALB ログは S3 に gzip で置かれるため Logs Insights では見られない。
- `scripts/download-alb-logs.sh` でローカルへ取得 → `scripts/alb_logs_to_csv.py` で CSV 化 → MCP / AI に渡す
- 本格的にSQLで見たい場合は Athena（AWS公式ドキュメント「Application Load Balancer ログのクエリ」の CREATE TABLE 文を使う。スキャン料は数円以下）

ALB ログには WAF に BLOCK されたリクエストも `elb_status_code=403` として残る（`actions_executed` に `waf` が入る）。
