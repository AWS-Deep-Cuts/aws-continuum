# 設計: 取引先ポータル

`requirements.md` の要件を、今の `app.py` に 2 つのエンドポイントを足して実現します。

## エンドポイント

### `POST /partner/orders`

- リクエストの本文は、注文の CSV（列 `title,jacket`）です。
- ヘッダー `X-Partner-Key` の API キーで、取引先を識別します。API キーが `data/partners.csv` に無ければ、401 を返します。
- 本文を `inbox/<取引先>/<受け付けた日時>.csv` に保存します。日時の形は `YYYYMMDD-HHMMSS` です。
- 応答の本文は、保存したファイル名を JSON で返します。例: `{"order": "20261104-153000.csv"}`

### `GET /partner/report?order=<ファイル名>`

- ヘッダー `X-Partner-Key` の API キーで、取引先を識別します。
- `inbox/<取引先>/<ファイル名>` を、既存の `partner_report.build_report()` に渡します。
- `build_report()` が返した文字列を、`text/plain` でそのまま返します。

## データ

### `data/partners.csv`

| 列 | 内容 |
| --- | --- |
| `partner` | 取引先の名前。`inbox/` の下のフォルダーの名前にも使う |
| `api_key` | 取引先ごとに発行した API キー |

## 既存のコードの再利用

- 報告の作成は、既存の `build_report()` をそのまま使います。変更はしません。
- 検索 API の `/records` と `/records/top` は変更しません。

## 運用

- 取引先ポータルも、検索 API と同じサーバーで動かし、インターネットに公開します。
- 店の担当者は、これまでどおり `partner_report.py` をコマンドとしても使えます。
