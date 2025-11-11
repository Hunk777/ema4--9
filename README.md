# EMA Cross Trading System

高度なEMAクロス戦略を実装したトレーディングインジケーター・EA集

## 📁 プロジェクト構成

```
ema4--9/
├── pine_scripts/           # TradingView Pine Script
│   ├── EMA_Cross_Pro_v1.pine      # 最新版メインインジケーター
│   ├── strategy/                   # Strategy版
│   │   └── b1.pine                # 自動売買戦略版
│   └── development/                # 開発履歴
│       ├── a20.pine               # ST→SL変換版
│       ├── a21.x.pine             # SL3トレーリング開発
│       ├── a22.pine               # TP1追加版
│       ├── a23.x.pine             # SL2追加版
│       └── a24.x.pine             # 背景色シグナル版
├── mql5/                   # MetaTrader 4/5 EA
│   ├── EMA_Cross_BTCUSD_Pro.mq5
│   ├── EMA_Cross_For_Scal_Pro.mq5
│   └── その他EA
└── README.md               # このファイル
```

## 🎯 EMA Cross Pro v1.0 の特徴

### コアロジック
- **EMA 4 × EMA 9** クロス戦略
- 高速EMAと標準EMAのゴールデンクロス/デッドクロスでエントリー

### リスク管理機能

#### **SL2 (Stop Loss 2)**
- SL1を基準としたストップロス
- デフォルト: 0.5%
- LONG時: SL1より下、SHORT時: SL1より上

#### **SL1 (Stop Loss 1)**
- EMA交差価格（エントリー基準価格）
- シグナル発生時の2つのEMAの平均値

#### **TP1 (Take Profit 1)**
- 最低利益保証ライン
- デフォルト: 0.05%
- 確実に利益を確保する第一目標

#### **TP2 (Take Profit 2)**
- 動的トレーリングTP
- SL1と最高/最低価格の間の位置（デフォルト: 50%）
- 価格が伸びれば自動的に追従

### ビジュアル機能
- ✅ シグナル背景色表示（LONG: 緑 / SHORT: 赤）
- ✅ 水平ライン表示（SL1, SL2, TP1, TP2）
- ✅ 情報パネル（リアルタイム価格・損益表示）
- ✅ クロスシグナルマーカー
- ✅ EMA間塗りつぶし

### アラート機能
- ロングシグナルアラート
- ショートシグナルアラート

## 🚀 使い方

### TradingView

1. TradingViewを開く
2. チャートを表示
3. インジケーター追加
4. `pine_scripts/EMA_Cross_Pro_v1.pine` の内容をコピー&ペースト
5. 保存して適用

### 推奨設定

```
Fast EMA: 4
Standard EMA: 9
SL2 Offset: 0.5%
TP1 Offset: 0.05%
TP2 Position: 50%
```

### カスタマイズ可能な設定

- EMA期間（Fast/Standard）
- 各ライン表示ON/OFF
- SL2オフセット%
- TP1オフセット%
- TP2位置比率%
- ラベル位置

## 📊 バックテスト

Strategy版（`pine_scripts/strategy/b1.pine`）を使用することで、TradingViewの組み込みバックテスト機能を利用できます。

## 🔧 開発履歴

### a20.pine → a24.2.pine
1. **a20**: ST→SL表記変更
2. **a21.x**: SL3トレーリングストップ実装
3. **a22**: TP1（Take Profit 1）追加
4. **a23.x**: SL2（Stop Loss 2）追加、情報パネル改善
5. **a24.x**: シグナル背景色表示追加

### 最終版: EMA_Cross_Pro_v1.pine
- 全機能統合
- UIの最適化
- パフォーマンス改善

## 📝 ライセンス

このプロジェクトは個人使用・学習目的で公開されています。

## 🤝 コントリビューション

バグ報告や機能追加の提案は Issue からお願いします。

## ⚠️ 免責事項

このインジケーターは教育・研究目的で提供されています。
実際の取引での使用は自己責任でお願いします。
過去の成績は将来の結果を保証するものではありません。

---

**開発者**: Hunk777
**最終更新**: 2025-01-12
**バージョン**: v1.0
