//+------------------------------------------------------------------+
//|                         EMA_Cross_For_Scal.mq5                   |
//|                  秒足ベースEMAクロス戦略 - スキャル専用          |
//|                                              Copyright 2024      |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024"
#property link      ""
#property version   "1.00"
#property description "秒足ベースのリアルタイムEMAクロス - 超高速スキャルピング"

// 秒足バー構造体
struct SecondBar
{
    datetime time;
    double open;
    double high;
    double low;
    double close;
    long volume;
};

// インプットパラメータ
input group "===== 秒足設定 ====="
input int      InpSecondsPerBar = 10;        // 秒足期間（秒）
input int      InpSecondBarHistory = 500;    // 秒足履歴保存数

input group "===== EMA設定 ====="
input int      InpEMA_Fast = 5;              // 短期EMA期間（秒足ベース）
input int      InpEMA_Slow = 13;             // 長期EMA期間（秒足ベース）
input ENUM_APPLIED_PRICE InpAppliedPrice = PRICE_CLOSE; // 適用価格
input bool     InpShowEMAOnChart = true;     // チャート上にEMAを表示
input color    InpColorFastEMA = clrAqua;    // 短期EMAの色
input color    InpColorSlowEMA = clrMagenta; // 長期EMAの色

input group "===== クロス検出設定 ====="
input double   InpCrossThreshold = 0.00001;  // クロス判定閾値（最小差）
input int      InpConfirmBars = 1;           // 確認バー数（1=即時実行）

input group "===== フィルター設定 ====="
input bool     InpUseSpreadFilter = true;    // スプレッドフィルター
input double   InpMaxSpreadPips = 2.0;       // 最大スプレッド（pips）

input bool     InpUseVolatilityFilter = true; // ボラティリティフィルター
input int      InpATRPeriod = 14;            // ATR期間（秒足ベース）
input double   InpMinATRPips = 0.5;          // 最小ATR（pips）

input bool     InpUseTrendFilter = false;    // トレンドフィルター
input int      InpTrendPeriod = 50;          // トレンドEMA期間
input bool     InpTradeWithTrendOnly = false; // トレンド方向のみ取引

input group "===== 取引設定 ====="
input double   InpLotSize = 0.1;             // ロットサイズ
input int      InpMagicNumber = 20241213;    // マジックナンバー
input string   InpComment = "SCAL";          // 注文コメント
input int      InpSlippage = 10;             // スリッページ (points)
input int      InpMinTradeIntervalSeconds = 10; // 最小取引間隔（秒）

input group "===== リスク管理 ====="
input bool     InpUseDynamicSL = true;       // 動的ストップロス
input double   InpSLATRMultiplier = 1.5;     // SL用ATR倍率
input double   InpMinSLPips = 3;             // 最小SL（pips）
input double   InpMaxSLPips = 20;            // 最大SL（pips）

input bool     InpUseDynamicTP = true;       // 動的テイクプロフィット
input double   InpTPATRMultiplier = 2.5;     // TP用ATR倍率
input double   InpMinTPPips = 5;             // 最小TP（pips）
input double   InpMaxTPPips = 40;            // 最大TP（pips）

input bool     InpUseTrailingStop = false;   // トレイリングストップ
input double   InpTrailingStart = 10;        // トレイリング開始（pips）
input double   InpTrailingStep = 5;          // トレイリングステップ（pips）

input group "===== 表示設定 ====="
input bool     InpShowInfoPanel = true;      // 情報パネルを表示
input bool     InpShowCrossSignals = true;   // クロスシグナルを表示
input bool     InpShowDebugInfo = false;     // デバッグ情報

// グローバル変数
SecondBar g_secondBars[];                     // 秒足バー配列
int g_secondBarsCount = 0;                    // 秒足バー数
datetime g_currentBarStartTime = 0;           // 現在バー開始時刻
SecondBar g_currentBar;                       // 現在構築中のバー

// EMA配列
double g_fastEMA[];                           // 短期EMA配列
double g_slowEMA[];                           // 長期EMA配列
double g_trendEMA[];                          // トレンドEMA配列
double g_atrValues[];                         // ATR配列

// EMA計算用
double g_fastEMA_Current = 0;                 // 現在の短期EMA
double g_slowEMA_Current = 0;                 // 現在の長期EMA
double g_trendEMA_Current = 0;                // 現在のトレンドEMA
bool g_emaInitialized = false;                // EMA初期化フラグ

// クロス検出用
int g_lastCrossType = 0;                      // 最後のクロスタイプ（1:GC, -1:DC）
datetime g_lastCrossTime = 0;                 // 最後のクロス時刻
int g_crossConfirmCount = 0;                  // クロス確認カウント

// 取引管理
datetime g_lastTradeTime = 0;                 // 最後の取引時刻
int g_currentPosition = 0;                    // 現在のポジション（1:買い, -1:売り, 0:なし）
bool g_tradeExecuting = false;                // 取引実行中フラグ
ulong g_currentTicket = 0;                    // 現在のポジションチケット

// 統計
int g_totalSignals = 0;                       // 総シグナル数
int g_tradedSignals = 0;                      // 取引実行シグナル数
int g_filteredSignals = 0;                    // フィルター除外数
double g_totalProfit = 0;                     // 総利益
int g_winCount = 0;                           // 勝ち数
int g_loseCount = 0;                          // 負け数

// パフォーマンス
int g_ticksProcessed = 0;                     // 処理ティック数
int g_barsCreated = 0;                        // 生成バー数
datetime g_startTime = 0;                     // 開始時刻

// UI要素
string g_prefix = "SCAL_";

//+------------------------------------------------------------------+
//| 初期化関数                                                      |
//+------------------------------------------------------------------+
int OnInit()
{
    Print("========================================");
    Print("EMA CROSS FOR SCAL v1.0 - 起動");
    Print("秒足期間: ", InpSecondsPerBar, "秒");
    Print("EMA期間: ", InpEMA_Fast, "/", InpEMA_Slow, " (秒足ベース)");
    Print("========================================");

    // パラメータ検証
    if(InpSecondsPerBar < 1 || InpSecondsPerBar > 60) {
        Print("エラー: 秒足期間は1-60秒の範囲で設定してください");
        return(INIT_PARAMETERS_INCORRECT);
    }

    if(InpEMA_Fast >= InpEMA_Slow) {
        Print("エラー: 短期EMAは長期EMAより小さく設定してください");
        return(INIT_PARAMETERS_INCORRECT);
    }

    // 配列初期化
    ArrayResize(g_secondBars, InpSecondBarHistory);
    ArraySetAsSeries(g_secondBars, true);

    ArrayResize(g_fastEMA, InpSecondBarHistory);
    ArraySetAsSeries(g_fastEMA, true);

    ArrayResize(g_slowEMA, InpSecondBarHistory);
    ArraySetAsSeries(g_slowEMA, true);

    ArrayResize(g_trendEMA, InpSecondBarHistory);
    ArraySetAsSeries(g_trendEMA, true);

    ArrayResize(g_atrValues, InpSecondBarHistory);
    ArraySetAsSeries(g_atrValues, true);

    // 初期バーの準備
    g_currentBarStartTime = TimeCurrent();
    g_currentBarStartTime -= g_currentBarStartTime % InpSecondsPerBar; // 秒単位で切り捨て

    MqlTick tick;
    if(SymbolInfoTick(_Symbol, tick)) {
        g_currentBar.time = g_currentBarStartTime;
        g_currentBar.open = tick.last;
        g_currentBar.high = tick.last;
        g_currentBar.low = tick.last;
        g_currentBar.close = tick.last;
        g_currentBar.volume = tick.volume;
    }

    // 過去の1分足データから秒足を初期化
    InitializeFromMinuteBars();

    // UI作成
    if(InpShowInfoPanel) CreateInfoPanel();

    g_startTime = TimeCurrent();

    Print("初期化完了 - 秒足バー数: ", g_secondBarsCount);
    Print("========================================");

    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| 終了処理                                                        |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    ObjectsDeleteAll(0, g_prefix);

    // 統計表示
    Print("========================================");
    Print("【終了統計】");
    Print("稼働時間: ", (TimeCurrent() - g_startTime), "秒");
    Print("処理ティック数: ", g_ticksProcessed);
    Print("生成秒足バー数: ", g_barsCreated);
    Print("総シグナル: ", g_totalSignals);
    Print("取引実行: ", g_tradedSignals);
    Print("フィルター除外: ", g_filteredSignals);
    Print("実行率: ", g_totalSignals > 0 ?
          DoubleToString(100.0 * g_tradedSignals / g_totalSignals, 1) + "%" : "N/A");
    Print("勝敗: ", g_winCount, "勝 / ", g_loseCount, "敗");
    Print("勝率: ", (g_winCount + g_loseCount) > 0 ?
          DoubleToString(100.0 * g_winCount / (g_winCount + g_loseCount), 1) + "%" : "N/A");
    Print("総損益: ", DoubleToString(g_totalProfit, 2));
    Print("========================================");
}

//+------------------------------------------------------------------+
//| ティック処理                                                    |
//+------------------------------------------------------------------+
void OnTick()
{
    g_ticksProcessed++;

    MqlTick tick;
    if(!SymbolInfoTick(_Symbol, tick)) return;

    datetime currentTime = TimeCurrent();

    // 新しい秒足バーが必要か確認
    datetime barStartTime = currentTime - (currentTime % InpSecondsPerBar);

    if(barStartTime > g_currentBarStartTime) {
        // 前のバーを確定して配列に追加
        FinalizeCurrentBar();

        // 新しいバーを開始
        StartNewBar(tick, barStartTime);

        // EMA計算とシグナル検出
        if(g_secondBarsCount >= InpEMA_Slow) {
            CalculateEMA();
            int signal = DetectCross();

            if(signal != 0) {
                ProcessSignal(signal);
            }
        }
    } else {
        // 現在のバーを更新
        UpdateCurrentBar(tick);
    }

    // トレイリングストップ
    if(InpUseTrailingStop && g_currentTicket > 0) {
        TrailingStop();
    }

    // 表示更新（パフォーマンス考慮で間引き）
    if(g_ticksProcessed % 10 == 0) {
        UpdateDisplay();
    }
}

//+------------------------------------------------------------------+
//| 1分足から秒足を初期化                                           |
//+------------------------------------------------------------------+
void InitializeFromMinuteBars()
{
    // 1分足データを取得
    MqlRates rates[];
    ArraySetAsSeries(rates, true);

    int needed = MathMax(InpEMA_Slow, InpTrendPeriod) * InpSecondsPerBar / 60 + 10;
    int copied = CopyRates(_Symbol, PERIOD_M1, 0, needed, rates);

    if(copied <= 0) {
        Print("警告: 1分足データの取得に失敗。リアルタイムから開始します。");
        return;
    }

    // 1分足を秒足に分割（簡易版：各1分足を均等に分割）
    int barsPerMinute = 60 / InpSecondsPerBar;

    for(int i = copied - 1; i >= 0 && g_secondBarsCount < InpSecondBarHistory; i--) {
        double priceStep = (rates[i].close - rates[i].open) / barsPerMinute;
        double highStep = (rates[i].high - rates[i].open) / barsPerMinute;
        double lowStep = (rates[i].low - rates[i].open) / barsPerMinute;

        for(int j = 0; j < barsPerMinute && g_secondBarsCount < InpSecondBarHistory; j++) {
            SecondBar bar;
            bar.time = rates[i].time + j * InpSecondsPerBar;
            bar.open = rates[i].open + priceStep * j;
            bar.close = rates[i].open + priceStep * (j + 1);
            bar.high = MathMax(bar.open, bar.close) + MathAbs(highStep) * 0.5;
            bar.low = MathMin(bar.open, bar.close) - MathAbs(lowStep) * 0.5;
            bar.volume = rates[i].tick_volume / barsPerMinute;

            // 配列をシフトして新しいバーを追加
            for(int k = InpSecondBarHistory - 1; k > 0; k--) {
                g_secondBars[k] = g_secondBars[k-1];
            }
            g_secondBars[0] = bar;
            g_secondBarsCount++;
        }
    }

    Print("1分足から秒足を初期化: ", g_secondBarsCount, "本生成");
}

//+------------------------------------------------------------------+
//| 現在バーを確定                                                  |
//+------------------------------------------------------------------+
void FinalizeCurrentBar()
{
    // 配列をシフト
    for(int i = InpSecondBarHistory - 1; i > 0; i--) {
        g_secondBars[i] = g_secondBars[i-1];
    }

    // 新しいバーを先頭に追加
    g_secondBars[0] = g_currentBar;

    if(g_secondBarsCount < InpSecondBarHistory) {
        g_secondBarsCount++;
    }

    g_barsCreated++;

    if(InpShowDebugInfo && g_barsCreated % 10 == 0) {
        Print("秒足バー生成: ", g_barsCreated, "本目 | ",
              "Time: ", TimeToString(g_currentBar.time, TIME_SECONDS),
              " O:", g_currentBar.open,
              " H:", g_currentBar.high,
              " L:", g_currentBar.low,
              " C:", g_currentBar.close);
    }
}

//+------------------------------------------------------------------+
//| 新しいバーを開始                                                |
//+------------------------------------------------------------------+
void StartNewBar(MqlTick &tick, datetime barStartTime)
{
    g_currentBarStartTime = barStartTime;
    g_currentBar.time = barStartTime;
    g_currentBar.open = tick.last;
    g_currentBar.high = tick.last;
    g_currentBar.low = tick.last;
    g_currentBar.close = tick.last;
    g_currentBar.volume = tick.volume;
}

//+------------------------------------------------------------------+
//| 現在バーを更新                                                  |
//+------------------------------------------------------------------+
void UpdateCurrentBar(MqlTick &tick)
{
    g_currentBar.high = MathMax(g_currentBar.high, tick.last);
    g_currentBar.low = MathMin(g_currentBar.low, tick.last);
    g_currentBar.close = tick.last;
    g_currentBar.volume += tick.volume;
}

//+------------------------------------------------------------------+
//| EMA計算                                                         |
//+------------------------------------------------------------------+
void CalculateEMA()
{
    if(g_secondBarsCount < InpEMA_Slow) return;

    double alphaFast = 2.0 / (InpEMA_Fast + 1.0);
    double alphaSlow = 2.0 / (InpEMA_Slow + 1.0);
    double alphaTrend = 2.0 / (InpTrendPeriod + 1.0);

    // 初回計算
    if(!g_emaInitialized) {
        // SMAから開始
        double sumFast = 0, sumSlow = 0, sumTrend = 0;

        for(int i = 0; i < InpEMA_Fast; i++) {
            sumFast += GetPrice(i);
        }
        g_fastEMA_Current = sumFast / InpEMA_Fast;

        for(int i = 0; i < InpEMA_Slow; i++) {
            sumSlow += GetPrice(i);
        }
        g_slowEMA_Current = sumSlow / InpEMA_Slow;

        if(InpUseTrendFilter && g_secondBarsCount >= InpTrendPeriod) {
            for(int i = 0; i < InpTrendPeriod; i++) {
                sumTrend += GetPrice(i);
            }
            g_trendEMA_Current = sumTrend / InpTrendPeriod;
        }

        g_emaInitialized = true;
    } else {
        // EMA更新
        double price = GetPrice(0);
        g_fastEMA_Current = price * alphaFast + g_fastEMA_Current * (1.0 - alphaFast);
        g_slowEMA_Current = price * alphaSlow + g_slowEMA_Current * (1.0 - alphaSlow);

        if(InpUseTrendFilter) {
            g_trendEMA_Current = price * alphaTrend + g_trendEMA_Current * (1.0 - alphaTrend);
        }
    }

    // 配列に保存
    g_fastEMA[0] = g_fastEMA_Current;
    g_slowEMA[0] = g_slowEMA_Current;
    g_trendEMA[0] = g_trendEMA_Current;

    // ATR計算
    CalculateATR();
}

//+------------------------------------------------------------------+
//| ATR計算                                                         |
//+------------------------------------------------------------------+
void CalculateATR()
{
    if(g_secondBarsCount < InpATRPeriod + 1) return;

    double sum = 0;
    for(int i = 1; i <= InpATRPeriod; i++) {
        double tr = MathMax(g_secondBars[i-1].high - g_secondBars[i-1].low,
                    MathMax(MathAbs(g_secondBars[i-1].high - g_secondBars[i].close),
                            MathAbs(g_secondBars[i-1].low - g_secondBars[i].close)));
        sum += tr;
    }

    g_atrValues[0] = sum / InpATRPeriod;
}

//+------------------------------------------------------------------+
//| 価格取得                                                        |
//+------------------------------------------------------------------+
double GetPrice(int index)
{
    if(index >= g_secondBarsCount) return 0;

    switch(InpAppliedPrice) {
        case PRICE_OPEN: return g_secondBars[index].open;
        case PRICE_HIGH: return g_secondBars[index].high;
        case PRICE_LOW: return g_secondBars[index].low;
        case PRICE_CLOSE: return g_secondBars[index].close;
        case PRICE_MEDIAN: return (g_secondBars[index].high + g_secondBars[index].low) / 2.0;
        case PRICE_TYPICAL: return (g_secondBars[index].high + g_secondBars[index].low + g_secondBars[index].close) / 3.0;
        case PRICE_WEIGHTED: return (g_secondBars[index].high + g_secondBars[index].low + 2 * g_secondBars[index].close) / 4.0;
    }

    return g_secondBars[index].close;
}

//+------------------------------------------------------------------+
//| クロス検出                                                      |
//+------------------------------------------------------------------+
int DetectCross()
{
    if(g_secondBarsCount < 2) return 0;

    // 前回のEMA値を取得（配列の1番目）
    double prevFast = g_fastEMA[1];
    double prevSlow = g_slowEMA[1];

    if(prevFast == 0 || prevSlow == 0) return 0;

    // 現在の差と前回の差
    double currentDiff = g_fastEMA_Current - g_slowEMA_Current;
    double prevDiff = prevFast - prevSlow;

    // クロス判定
    if(MathAbs(currentDiff) < InpCrossThreshold) return 0;

    // ゴールデンクロス
    if(prevDiff <= 0 && currentDiff > 0) {
        g_crossConfirmCount++;
        if(g_crossConfirmCount >= InpConfirmBars) {
            g_lastCrossType = 1;
            g_lastCrossTime = TimeCurrent();
            g_crossConfirmCount = 0;

            if(InpShowDebugInfo) {
                Print("【GC検出】Fast:", g_fastEMA_Current, " Slow:", g_slowEMA_Current);
            }

            return 1;
        }
    }
    // デッドクロス
    else if(prevDiff >= 0 && currentDiff < 0) {
        g_crossConfirmCount++;
        if(g_crossConfirmCount >= InpConfirmBars) {
            g_lastCrossType = -1;
            g_lastCrossTime = TimeCurrent();
            g_crossConfirmCount = 0;

            if(InpShowDebugInfo) {
                Print("【DC検出】Fast:", g_fastEMA_Current, " Slow:", g_slowEMA_Current);
            }

            return -1;
        }
    } else {
        g_crossConfirmCount = 0;
    }

    return 0;
}

//+------------------------------------------------------------------+
//| シグナル処理                                                    |
//+------------------------------------------------------------------+
void ProcessSignal(int signal)
{
    g_totalSignals++;

    // フィルターチェック
    if(!CheckFilters(signal)) {
        g_filteredSignals++;
        if(InpShowDebugInfo) {
            Print("シグナル除外: ", signal == 1 ? "買い" : "売り");
        }
        return;
    }

    // 取引実行条件
    if(!CanExecuteTrade()) {
        if(InpShowDebugInfo) {
            Print("取引間隔制限: 最終取引から ",
                  (TimeCurrent() - g_lastTradeTime), "秒経過");
        }
        return;
    }

    // 取引実行
    ExecuteTrade(signal);
}

//+------------------------------------------------------------------+
//| フィルターチェック                                              |
//+------------------------------------------------------------------+
bool CheckFilters(int signal)
{
    // スプレッドフィルター
    if(InpUseSpreadFilter) {
        double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
        double spreadPips = spread / _Point / 10;

        if(spreadPips > InpMaxSpreadPips) {
            if(InpShowDebugInfo) {
                Print("スプレッド除外: ", spreadPips, " pips");
            }
            return false;
        }
    }

    // ボラティリティフィルター
    if(InpUseVolatilityFilter && g_atrValues[0] > 0) {
        double atrPips = g_atrValues[0] / _Point / 10;

        if(atrPips < InpMinATRPips) {
            if(InpShowDebugInfo) {
                Print("ATR除外: ", atrPips, " pips");
            }
            return false;
        }
    }

    // トレンドフィルター
    if(InpUseTrendFilter && InpTradeWithTrendOnly) {
        double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);

        if(signal == 1 && price < g_trendEMA_Current) {
            if(InpShowDebugInfo) {
                Print("トレンド除外: 買いシグナルだが価格がトレンドEMA下");
            }
            return false;
        }

        if(signal == -1 && price > g_trendEMA_Current) {
            if(InpShowDebugInfo) {
                Print("トレンド除外: 売りシグナルだが価格がトレンドEMA上");
            }
            return false;
        }
    }

    return true;
}

//+------------------------------------------------------------------+
//| 取引実行可能チェック                                            |
//+------------------------------------------------------------------+
bool CanExecuteTrade()
{
    if(g_tradeExecuting) return false;

    if(g_lastTradeTime > 0) {
        int elapsed = (int)(TimeCurrent() - g_lastTradeTime);
        if(elapsed < InpMinTradeIntervalSeconds) {
            return false;
        }
    }

    return true;
}

//+------------------------------------------------------------------+
//| 取引実行                                                        |
//+------------------------------------------------------------------+
void ExecuteTrade(int signal)
{
    g_tradeExecuting = true;

    // 既存ポジション決済
    if(g_currentPosition != 0 && g_currentTicket > 0) {
        ClosePosition(g_currentTicket);
    }

    MqlTradeRequest request = {};
    MqlTradeResult result = {};

    double point = _Point;
    double atr = g_atrValues[0];
    double sl = 0, tp = 0;

    // SL/TP計算
    if(InpUseDynamicSL && atr > 0) {
        double slDistance = atr * InpSLATRMultiplier;
        slDistance = MathMax(InpMinSLPips * point * 10, slDistance);
        slDistance = MathMin(InpMaxSLPips * point * 10, slDistance);

        if(signal == 1) {
            sl = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - slDistance;
        } else {
            sl = SymbolInfoDouble(_Symbol, SYMBOL_BID) + slDistance;
        }
    }

    if(InpUseDynamicTP && atr > 0) {
        double tpDistance = atr * InpTPATRMultiplier;
        tpDistance = MathMax(InpMinTPPips * point * 10, tpDistance);
        tpDistance = MathMin(InpMaxTPPips * point * 10, tpDistance);

        if(signal == 1) {
            tp = SymbolInfoDouble(_Symbol, SYMBOL_ASK) + tpDistance;
        } else {
            tp = SymbolInfoDouble(_Symbol, SYMBOL_BID) - tpDistance;
        }
    }

    // 注文設定
    request.action = TRADE_ACTION_DEAL;
    request.symbol = _Symbol;
    request.volume = InpLotSize;
    request.magic = InpMagicNumber;
    request.deviation = InpSlippage;
    request.type_filling = GetFillingMode();

    if(signal == 1) {
        request.type = ORDER_TYPE_BUY;
        request.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        request.comment = InpComment + "_BUY";
    } else {
        request.type = ORDER_TYPE_SELL;
        request.price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        request.comment = InpComment + "_SELL";
    }

    request.sl = sl > 0 ? NormalizeDouble(sl, _Digits) : 0;
    request.tp = tp > 0 ? NormalizeDouble(tp, _Digits) : 0;

    // 注文送信
    if(OrderSend(request, result)) {
        g_tradedSignals++;
        g_lastTradeTime = TimeCurrent();
        g_currentPosition = signal;
        g_currentTicket = result.order;

        Print("【取引実行】",
              signal == 1 ? "買い" : "売り",
              " | 価格:", DoubleToString(request.price, _Digits),
              " | SL:", sl > 0 ? DoubleToString(MathAbs(request.price - sl) / point / 10, 1) + "pips" : "なし",
              " | TP:", tp > 0 ? DoubleToString(MathAbs(tp - request.price) / point / 10, 1) + "pips" : "なし",
              " | Ticket:", result.order);

        // シグナル表示
        if(InpShowCrossSignals) {
            DrawSignalArrow(signal);
        }
    } else {
        Print("取引エラー: ", result.retcode, " - ", result.comment);
    }

    g_tradeExecuting = false;
}

//+------------------------------------------------------------------+
//| ポジション決済                                                  |
//+------------------------------------------------------------------+
void ClosePosition(ulong ticket)
{
    if(!PositionSelectByTicket(ticket)) return;

    MqlTradeRequest request = {};
    MqlTradeResult result = {};

    request.action = TRADE_ACTION_DEAL;
    request.position = ticket;
    request.symbol = _Symbol;
    request.volume = PositionGetDouble(POSITION_VOLUME);
    request.deviation = InpSlippage;
    request.magic = InpMagicNumber;
    request.type_filling = GetFillingMode();

    ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

    if(type == POSITION_TYPE_BUY) {
        request.type = ORDER_TYPE_SELL;
        request.price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    } else {
        request.type = ORDER_TYPE_BUY;
        request.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    }

    if(OrderSend(request, result)) {
        double profit = PositionGetDouble(POSITION_PROFIT);
        g_totalProfit += profit;

        if(profit > 0) g_winCount++;
        else if(profit < 0) g_loseCount++;

        g_currentPosition = 0;
        g_currentTicket = 0;

        Print("【決済】Profit: ", DoubleToString(profit, 2));
    }
}

//+------------------------------------------------------------------+
//| トレイリングストップ                                            |
//+------------------------------------------------------------------+
void TrailingStop()
{
    if(!PositionSelectByTicket(g_currentTicket)) return;

    double currentSL = PositionGetDouble(POSITION_SL);
    double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
    double currentPrice;

    ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

    if(type == POSITION_TYPE_BUY) {
        currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        double profit = currentPrice - openPrice;

        if(profit >= InpTrailingStart * _Point * 10) {
            double newSL = currentPrice - InpTrailingStep * _Point * 10;

            if(newSL > currentSL) {
                ModifyPosition(g_currentTicket, newSL, PositionGetDouble(POSITION_TP));
            }
        }
    } else {
        currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        double profit = openPrice - currentPrice;

        if(profit >= InpTrailingStart * _Point * 10) {
            double newSL = currentPrice + InpTrailingStep * _Point * 10;

            if(newSL < currentSL || currentSL == 0) {
                ModifyPosition(g_currentTicket, newSL, PositionGetDouble(POSITION_TP));
            }
        }
    }
}

//+------------------------------------------------------------------+
//| ポジション変更                                                  |
//+------------------------------------------------------------------+
void ModifyPosition(ulong ticket, double sl, double tp)
{
    MqlTradeRequest request = {};
    MqlTradeResult result = {};

    request.action = TRADE_ACTION_SLTP;
    request.position = ticket;
    request.symbol = _Symbol;
    request.sl = NormalizeDouble(sl, _Digits);
    request.tp = NormalizeDouble(tp, _Digits);

    OrderSend(request, result);
}

//+------------------------------------------------------------------+
//| フィリングモード取得                                            |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetFillingMode()
{
    int filling = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);

    if((filling & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
    if((filling & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;

    return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
//| 情報パネル作成                                                  |
//+------------------------------------------------------------------+
void CreateInfoPanel()
{
    int panelHeight = 280;

    ObjectCreate(0, g_prefix + "PANEL_BG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
    ObjectSetInteger(0, g_prefix + "PANEL_BG", OBJPROP_CORNER, CORNER_LEFT_UPPER);
    ObjectSetInteger(0, g_prefix + "PANEL_BG", OBJPROP_XDISTANCE, 10);
    ObjectSetInteger(0, g_prefix + "PANEL_BG", OBJPROP_YDISTANCE, 30);
    ObjectSetInteger(0, g_prefix + "PANEL_BG", OBJPROP_XSIZE, 320);
    ObjectSetInteger(0, g_prefix + "PANEL_BG", OBJPROP_YSIZE, panelHeight);
    ObjectSetInteger(0, g_prefix + "PANEL_BG", OBJPROP_BGCOLOR, C'20,20,30');
    ObjectSetInteger(0, g_prefix + "PANEL_BG", OBJPROP_BORDER_TYPE, BORDER_FLAT);
    ObjectSetInteger(0, g_prefix + "PANEL_BG", OBJPROP_COLOR, clrDodgerBlue);
}

//+------------------------------------------------------------------+
//| 表示更新                                                        |
//+------------------------------------------------------------------+
void UpdateDisplay()
{
    if(!InpShowInfoPanel) return;

    string info[];
    color colors[];
    ArrayResize(info, 14);
    ArrayResize(colors, 14);

    double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point / 10;
    double atrPips = g_atrValues[0] / _Point / 10;

    info[0] = "=== EMA CROSS FOR SCAL ===";
    colors[0] = clrYellow;

    info[1] = StringFormat("秒足: %d秒 | バー数: %d", InpSecondsPerBar, g_secondBarsCount);
    colors[1] = clrWhite;

    info[2] = StringFormat("Fast EMA(%d): %.5f", InpEMA_Fast, g_fastEMA_Current);
    colors[2] = InpColorFastEMA;

    info[3] = StringFormat("Slow EMA(%d): %.5f", InpEMA_Slow, g_slowEMA_Current);
    colors[3] = InpColorSlowEMA;

    info[4] = StringFormat("差分: %+.5f", g_fastEMA_Current - g_slowEMA_Current);
    colors[4] = g_fastEMA_Current > g_slowEMA_Current ? clrLime : clrRed;

    info[5] = StringFormat("ATR: %.2f pips", atrPips);
    colors[5] = atrPips >= InpMinATRPips ? clrLime : clrOrange;

    info[6] = StringFormat("スプレッド: %.1f pips", spread);
    colors[6] = spread <= InpMaxSpreadPips ? clrLime : clrOrange;

    info[7] = "------------------------";
    colors[7] = clrGray;

    info[8] = StringFormat("ポジション: %s",
        g_currentPosition == 1 ? "買い" : g_currentPosition == -1 ? "売り" : "なし");
    colors[8] = g_currentPosition == 1 ? clrLime : g_currentPosition == -1 ? clrRed : clrGray;

    info[9] = StringFormat("シグナル: %d / 実行: %d", g_totalSignals, g_tradedSignals);
    colors[9] = clrWhite;

    info[10] = StringFormat("除外: %d / 実行率: %.1f%%",
        g_filteredSignals,
        g_totalSignals > 0 ? 100.0 * g_tradedSignals / g_totalSignals : 0);
    colors[10] = clrCyan;

    info[11] = StringFormat("勝敗: %dW-%dL (%.1f%%)",
        g_winCount, g_loseCount,
        (g_winCount + g_loseCount) > 0 ? 100.0 * g_winCount / (g_winCount + g_loseCount) : 0);
    colors[11] = g_winCount > g_loseCount ? clrLime : clrOrange;

    info[12] = StringFormat("総損益: %.2f", g_totalProfit);
    colors[12] = g_totalProfit >= 0 ? clrLime : clrRed;

    info[13] = StringFormat("処理tick: %d / 稼働: %ds",
        g_ticksProcessed, (TimeCurrent() - g_startTime));
    colors[13] = clrGray;

    for(int i = 0; i < ArraySize(info); i++) {
        string objName = g_prefix + "INFO_" + IntegerToString(i);

        if(ObjectFind(0, objName) < 0) {
            ObjectCreate(0, objName, OBJ_LABEL, 0, 0, 0);
            ObjectSetInteger(0, objName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
            ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, 20);
            ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, 40 + i * 18);
            ObjectSetString(0, objName, OBJPROP_FONT, "Consolas");
            ObjectSetInteger(0, objName, OBJPROP_FONTSIZE, 8);
        }

        ObjectSetString(0, objName, OBJPROP_TEXT, info[i]);
        ObjectSetInteger(0, objName, OBJPROP_COLOR, colors[i]);
    }
}

//+------------------------------------------------------------------+
//| シグナル矢印描画                                                |
//+------------------------------------------------------------------+
void DrawSignalArrow(int signal)
{
    string name = g_prefix + "SIGNAL_" + TimeToString(TimeCurrent(), TIME_SECONDS);
    datetime time = TimeCurrent();
    double price = SymbolInfoDouble(_Symbol, signal == 1 ? SYMBOL_ASK : SYMBOL_BID);

    ObjectCreate(0, name, signal == 1 ? OBJ_ARROW_BUY : OBJ_ARROW_SELL, 0, time, price);
    ObjectSetInteger(0, name, OBJPROP_COLOR, signal == 1 ? clrLime : clrRed);
    ObjectSetInteger(0, name, OBJPROP_WIDTH, 3);
    ObjectSetInteger(0, name, OBJPROP_ANCHOR, signal == 1 ? ANCHOR_TOP : ANCHOR_BOTTOM);
}
//+------------------------------------------------------------------+