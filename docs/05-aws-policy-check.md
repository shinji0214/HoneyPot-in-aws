# AWS 規約チェック（ハニーポット計画）

調査日: 2026-10-30。AWS の公開文書を読んだ上での整理で、法的助言ではありません。最終判断は自己責任で、不安が残る場合は AWS サポートに確認してください。

## 結論

**この計画（受動的な Web ハニーポットを 48 時間公開し、届いたログを見るだけ）は、AWS の規約上問題なく実施できる。事前申請も不要。**

- AWS の規約にハニーポットを禁止・申請必須とする条項は無い（AUP・ペネトレーションテストポリシーとも「honeypot」への言及なし）
- 禁止されているのは「他者のシステムのセキュリティを侵害する」「DoS」「スパム」などの**こちらから外へ向けた行為**。この計画はこちらから何も送らない
- ただし規約上の責任は「アカウント内で起きた全ての活動」に及ぶ。万一 EC2 が乗っ取られて踏み台になれば、それは利用者の違反として扱われる。リスクの中心はここ

## 一次情報と該当箇所

| 文書 | 該当箇所 | この計画への影響 |
|---|---|---|
| [AWS Acceptable Use Policy](https://aws.amazon.com/aup/)（2021-07-01 更新） | 違法行為、他者の権利侵害、「ユーザー・ネットワーク・システムのセキュリティ、完全性、可用性を侵害すること」、スパムを禁止。「use, facilitate, or allow others to use」＝**他者に使わせることも含む** | 受け身の観測は該当しない。乗っ取られて攻撃に使われると「allow others」に当たり得る |
| 同上 | AWS は違反の疑いを調査し、該当リソースを無効化できる。利用者は是正に協力する義務 | Abuse 通報が来たら対応が必要（後述） |
| [AWS Customer Agreement](https://aws.amazon.com/agreement/)（2026-08-14 更新） | 2.1「アカウントで起きた全ての活動に責任を負う」（許可したかどうかに関係なく） | 踏み台化しても「乗っ取られたから知らない」は通らない |
| 同上 | 2.3 サービスを適切に設定・利用する責任 | SG・OS・nginx の設定は利用者責任（責任共有モデル） |
| 同上 | 4.1 セキュリティリスクや重大な違反があれば AWS は一時停止できる | 踏み台化すると EC2 だけでなくアカウントごと止まる可能性 |
| 同上 | 7.1 第三者からの請求について AWS を補償する義務 | 踏み台化で第三者に損害を与えた場合、責任は利用者側 |
| [Penetration Testing ポリシー](https://aws.amazon.com/security/penetration-testing/) | 許可サービスへの自己テストは事前承認不要。DoS／疑似 DoS・フラッディングは禁止。C2 を含むテストや「その他の疑似イベント」は 2 週間前までに申請 | 計画は攻撃もスキャンもしないので対象外。**動作確認（verify.sh・curl 数回）は自分の EC2/ALB へのテストとして許容範囲**。負荷試験ツールで叩くのは避ける |
| [責任共有モデル](https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/shared-responsibility.html) | ゲスト OS・アプリ・SG 設定は利用者責任 | 同上 |
| [Abuse 報告への対応](https://repost.aws/knowledge-center/aws-abuse-report) / [Abuse notice FAQ](https://repost.aws/articles/ARi420OrIGR0y_9pOOker1QQ/abuse-notice-faqs) | 通知には **24 時間以内**の返信が求められる。返信しないとリソースのブロックやアカウント停止の可能性。通知はルートの連絡先メール（と登録済みならセキュリティ代替連絡先）に届く | 観測中はメールを見られる状態にしておく |

## 準備物（honeypot-prep）との照合

規約リスクの中心である「踏み台化」に対して、準備物はすでに強めに対策済み。

| 項目 | 現状 | 評価 |
|---|---|---|
| 公開内容 | nginx の静的ページと 404 のみ。アプリ・脆弱なソフトなし | ◎ 乗っ取られる余地が非常に小さい（低対話型） |
| 受信 | ALB の 80 のみ。EC2 は ALB からの 80 のみ。22 は閉鎖、管理は SSM | ◎ |
| 送信 | EC2 は 443 のみ | ○ 他のポートへの攻撃には使えない。443 宛ての攻撃は理論上可能だが、侵入経路がほぼ無いので現実的なリスクは低い |
| IMDSv2 強制・最小 IAM | 済み | ◎ 認証情報の窃取に強い |
| 隔離 VPC | Peering/TGW/VPN なし | ◎ |
| `expose_ec2_directly = true` | EC2 の 80 を直接公開（22 は閉鎖のまま） | ○ 規約上は問題なし。公開面が nginx 本体に直接触れるぶん少し増えるだけ |
| `waf_count_mode = true` | WAF を検知のみにする | ○ 規約上は問題なし。届くのは静的 nginx なので影響は小さい |

## 観測中・前後に守ること（チェックリスト）

**やらないこと（ここを越えると規約違反や申請対象になる）**

- [ ] 攻撃元 IP へのスキャン・逆探知・反撃をしない（AUP の「他者のセキュリティ侵害」に当たり得る）
- [ ] 攻撃者が送ってきたマルウェアの URL を EC2 から取得・実行しない。取得したペイロードを公開・再配布しない
- [ ] 脆弱なアプリ（WordPress など）を「釣るため」に置かない。置くなら踏み台化リスクが跳ね上がるので、送信をさらに絞る設計に変える
- [ ] 自分の環境への動作確認で負荷試験ツールを使わない（DoS 扱いの禁止事項）

**やっておくこと**

- [ ] AWS アカウントのルートの連絡先メールが受信できることを確認。可能なら「代替連絡先 > セキュリティ」に普段見るメールを登録（Abuse 通知が届く）
- [ ] 観測中に Abuse 通知が来たら、24 時間以内に件名を変えずに返信。内容を確認し、必要なら `terraform destroy`（honeypot スタック）で即停止して、その旨を返信する
- [ ] GuardDuty で「こちらから外へ」の Finding（`Backdoor:EC2/*`, `CryptoCurrency:EC2/*`, `Trojan:EC2/*`, `UnauthorizedAccess:EC2/TorClient`, `Recon:EC2/Portscan`（自分が送信元のもの）など）が出たら、乗っ取りを疑って即撤収
  - `Recon:EC2/PortProbeUnprotectedPort` のような「外からこちらへ」の Finding はハニーポットとして想定どおりなので対応不要
- [ ] 48 時間で確実に撤収（docs/03）

## 規約外だが関連する注意（日本の法律面、参考）

- 自分のサーバーに届いた通信を記録・分析すること自体は一般的な運用の範囲。こちらから相手に何かする（不正アクセス禁止法などに触れ得る）のとは性質が違う
- 記事化する際は IP アドレスをマスク（README の方針どおり）。ログに認証情報らしき文字列が含まれていても、それを試さない

## 出典

- AWS Acceptable Use Policy: https://aws.amazon.com/aup/
- AWS Customer Agreement: https://aws.amazon.com/agreement/
- AWS Penetration Testing: https://aws.amazon.com/security/penetration-testing/
- 責任共有モデル（Well-Architected Security Pillar）: https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/shared-responsibility.html
- Review and respond to an AWS abuse report: https://repost.aws/knowledge-center/aws-abuse-report
- Abuse notice FAQs: https://repost.aws/articles/ARi420OrIGR0y_9pOOker1QQ/abuse-notice-faqs
