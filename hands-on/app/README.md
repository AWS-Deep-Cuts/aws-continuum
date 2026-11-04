# Record shop

レコード店の在庫を検索する API と、取引先向けの報告を作るコマンドです。Python 3.9 以上の標準ライブラリだけで動きます。

## 起動とテスト

```bash
python3 app.py                # http://127.0.0.1:8080 で待ち受ける。HOST と PORT で変更できる
python3 -m unittest -v        # テストを実行する
```

## エンドポイントとコマンド

| 入口 | 内容 |
| --- | --- |
| `GET /health` | 生存確認 |
| `GET /records?q=<語>` | 題名にその語を含むレコードを返す |
| `GET /records/top?by=<price\|year\|title>` | 指定した列の順に上位 3 件を返す |
| `python3 partner_report.py <注文の CSV>` | 注文の CSV から、取引先向けの報告を作る |

## ファイル

| ファイル | 内容 |
| --- | --- |
| `data/records.csv` | レコードの一覧 |
| `data/customers.csv` | 顧客の一覧 |
| `jackets/` | ジャケットの説明文 |
| `inbox/` | 取引先から届いた注文の CSV |
| `OPERATIONS.md` | 運用のメモ |
