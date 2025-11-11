//+------------------------------------------------------------------+
//|                     EMA_Cross_BTC_Light.mq5                      |
//|              BTCUSD専用 超軽量版 - エントリー確実実行             |
//|                                              Copyright 2024      |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024"
#property link      ""
#property version   "1.00"
#property description "BTCUSD専用超軽量版 - どんな環境でも動作"

#include <Trade\Trade.mqh>
CTrade g_trade;

//+------------------------------------------------------------------+
//| 秒足バー（最小構造）                                             |
//+------------------------------------------------------------------+
struct SBar
{
    datetime time;
    double open;
    double high;
    double low;
    double close;
    ulong buyVol;
    ulong sellVol;
};

//+------------------------------------------------------------------+
//| パラメータ（BTC最適化・軽量版）                                  |
//+------------------------------------------------------------------+
input group "===== 基本設定 ====="
input int      InpSecondsPerBar = 30;        // 秒足期間

input group "===== EMA（BTC最適化） ====="
input int      InpEMA_Fast = 5;              // 短期EMA
input int      InpEMA_Slow = 13;             // 長期EMA
input int      InpEMA_Trend = 34;            // トレンドEMA

input group "===== フィルター（緩め＝エントリーしやすい） ====="
input bool     InpUseTrendFilter = false;    // トレンドフィルター（デフォルトOFF）
input bool     InpUseVolumeFilter = false;   // ボリュームフィルター（デフォルトOFF）
input double   InpMinVolumeDelta = 0.55;     // 最小ボリューム比率（緩め）
input bool     InpUseSpreadFilter = false;   // スプレッドフィルター（デフォルトOFF）
input double   InpMaxSpreadUSD = 100.0;      // 最大スプレッド（緩め）
input bool     InpUseATRFilter = false;      // ATRフィルター（デフォルトOFF）
input int      InpATR_Period = 20;           // ATR期間（軽量化）
input double   InpMinATR_USD = 30.0;         // 最小ATR（緩め）
input double   InpMaxATR_USD = 3000.0;       // 最大ATR（緩め）

input group "===== 時間帯（24時間対応） ====="
input bool     InpUseTimeFilter = false;     // 時間フィルター（デフォルトOFF）
input int      InpStartHour = 0;             // 開始時刻（UTC）
input int      InpEndHour = 24;              // 終了時刻（UTC）

input group "===== ポジション管理 ====="
input double   InpFixedLots = 0.01;          // ロット
input int      InpMinTradeIntervalSec = 30;  // 最小取引間隔（短め）

input group "===== リスク管理（シンプル） ====="
input double   InpSL_USD = 150.0;            // 固定SL（USD）
input double   InpTP_USD = 250.0;            // 固定TP（USD）
input bool     InpUseTrailing = false;       // トレイリング（デフォルトOFF）
input double   InpTrailStart_USD = 200.0;    // トレイリング開始
input double   InpTrailStep_USD = 80.0;      // トレイリングステップ

input group "===== その他 ====="
input int      InpMagicNumber = 66666;       // マジックナンバー
input string   InpComment = "BTC_LIGHT";     // コメント
input bool     InpShowInfo = true;           // 情報表示
input bool     InpShowPanel = true;          // パネル表示

input group "===== EMAライン表示 ====="
input bool     InpShowEMALines = true;       // EMAライン表示
input bool     InpShowFastEMA = true;        // Fast EMA表示
input bool     InpShowSlowEMA = true;        // Slow EMA表示
input bool     InpShowTrendEMA = true;       // Trend EMA表示

//+------------------------------------------------------------------+
//| グローバル変数（最小限）                                         |
//+------------------------------------------------------------------+
SBar g_bars[30];                              // 30本のみ保存
int g_barCount = 0;
datetime g_currentBarTime = 0;
SBar g_currentBar;

double g_emaFast = 0, g_emaSlow = 0, g_emaTrend = 0;
double g_emaFast_prev = 0, g_emaSlow_prev = 0;
bool g_emaInit = false;

// EMA履歴（チャート描画用）
struct SEmaHistory {
    datetime time;
    double fast;
    double slow;
    double trend;
};
SEmaHistory g_emaHistory[50];
int g_emaHistoryCount = 0;

double g_atr = 0;

ulong g_ticket = 0;
int g_direction = 0;
datetime g_lastTradeTime = 0;

double g_lastBid = 0;
int g_digits = 0;

// 統計（最小限）
int g_totalTrades = 0;
int g_wins = 0;
double g_profit = 0;

// デバッグ
int g_totalSignals = 0;
int g_filteredSignals = 0;
int g_totalTicks = 0;

//+------------------------------------------------------------------+
//| 初期化                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
    Print("========================================");
    Print("BTC LIGHT - STARTING");
    Print("========================================");

    g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    g_trade.SetExpertMagicNumber(InpMagicNumber);
    g_trade.SetTypeFilling(ORDER_FILLING_IOC);
    g_trade.SetAsyncMode(false);

    MqlTick tick;
    if(SymbolInfoTick(_Symbol, tick)) {
        g_currentBarTime = TimeCurrent();
        g_currentBarTime -= g_currentBarTime % InpSecondsPerBar;
        g_currentBar.time = g_currentBarTime;
        g_currentBar.open = g_currentBar.high = g_currentBar.low = g_currentBar.close = tick.bid;
        g_currentBar.buyVol = g_currentBar.sellVol = 0;
        g_lastBid = tick.bid;
    }

    InitEMA();

    // パネル作成
    if(InpShowPanel) {
        CreatePanel();
    }

    PrintFormat("Symbol: %s | Seconds: %d | EMA: %d/%d/%d",
                _Symbol, InpSecondsPerBar, InpEMA_Fast, InpEMA_Slow, InpEMA_Trend);
    PrintFormat("Lots: %.4f | SL: $%.2f | TP: $%.2f",
                InpFixedLots, InpSL_USD, InpTP_USD);
    Print("========================================");
    Print("READY - WAITING FOR SIGNALS...");
    Print("========================================");

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| 終了処理                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    Print("========================================");
    Print("BTC LIGHT - STOPPED");
    PrintFormat("Ticks: %d | Bars: %d", g_totalTicks, g_barCount);
    PrintFormat("Signals: %d | Filtered: %d", g_totalSignals, g_filteredSignals);
    PrintFormat("Trades: %d | Wins: %d | P/L: $%.2f",
                g_totalTrades, g_wins, g_profit);
    Print("========================================");

    // パネル・EMAライン削除
    ObjectsDeleteAll(0, "BTC_");
}

//+------------------------------------------------------------------+
//| ティック処理（超軽量）                                           |
//+------------------------------------------------------------------+
void OnTick()
{
    g_totalTicks++;

    MqlTick tick;
    if(!SymbolInfoTick(_Symbol, tick)) return;

    datetime now = TimeCurrent();
    datetime barTime = now - (now % InpSecondsPerBar);

    // 新バー
    if(barTime > g_currentBarTime) {
        // 保存
        if(g_barCount < 30) {
            g_bars[g_barCount++] = g_currentBar;
        } else {
            // シフト
            for(int i = 0; i < 29; i++) {
                g_bars[i] = g_bars[i + 1];
            }
            g_bars[29] = g_currentBar;
        }

        // リセット
        g_currentBarTime = barTime;
        g_currentBar.time = barTime;
        g_currentBar.open = g_currentBar.high = g_currentBar.low = g_currentBar.close = tick.bid;
        g_currentBar.buyVol = g_currentBar.sellVol = 0;

        // EMA計算
        CalcEMA();

        // シグナル
        if(g_emaInit && g_barCount >= 2) {
            int sig = DetectSignal();
            if(sig != 0) {
                PrintFormat(">>> SIGNAL: %s | Price: $%.2f <<<",
                            sig == 1 ? "BUY" : "SELL", tick.bid);
                ProcessSignal(sig);
            }
        }

        // 10バーごとに状態表示
        if(g_barCount % 10 == 0 && InpShowInfo) {
            PrintStatus();
        }
    } else {
        // 更新
        if(tick.bid > g_currentBar.high) g_currentBar.high = tick.bid;
        if(tick.bid < g_currentBar.low) g_currentBar.low = tick.bid;
        g_currentBar.close = tick.bid;

        bool isBuy = (tick.bid >= g_lastBid);
        if(isBuy) g_currentBar.buyVol += tick.volume;
        else g_currentBar.sellVol += tick.volume;
    }

    g_lastBid = tick.bid;

    // トレイリング
    if(InpUseTrailing && g_ticket > 0 && g_totalTicks % 10 == 0) {
        UpdateTrailing();
    }

    // ポジションチェック（100ティックに1回）
    if(g_totalTicks % 100 == 0 && g_ticket > 0) {
        CheckClosed();
    }

    // パネル更新（30ティックに1回）
    if(InpShowPanel && g_totalTicks % 30 == 0) {
        UpdatePanel();
    }
}

//+------------------------------------------------------------------+
//| EMA初期化                                                        |
//+------------------------------------------------------------------+
void InitEMA()
{
    double close[];
    ArraySetAsSeries(close, true);

    int copied = CopyClose(_Symbol, PERIOD_M1, 0, InpEMA_Trend * 2, close);

    if(copied < InpEMA_Trend) {
        Print("Warning: Not enough history");
        if(copied > 0) {
            g_emaFast = g_emaSlow = g_emaTrend = close[0];
        }
        return;
    }

    double s1 = 0, s2 = 0, s3 = 0;
    for(int i = 0; i < InpEMA_Fast; i++) s1 += close[i];
    for(int i = 0; i < InpEMA_Slow; i++) s2 += close[i];
    for(int i = 0; i < InpEMA_Trend; i++) s3 += close[i];

    g_emaFast = s1 / InpEMA_Fast;
    g_emaSlow = s2 / InpEMA_Slow;
    g_emaTrend = s3 / InpEMA_Trend;

    g_emaFast_prev = g_emaFast;
    g_emaSlow_prev = g_emaSlow;

    g_emaInit = true;

    PrintFormat("EMA Init: Fast=$%.2f, Slow=$%.2f, Trend=$%.2f",
                g_emaFast, g_emaSlow, g_emaTrend);
}

//+------------------------------------------------------------------+
//| EMA計算                                                          |
//+------------------------------------------------------------------+
void CalcEMA()
{
    if(g_barCount == 0) return;

    double price = g_bars[g_barCount - 1].close;

    g_emaFast_prev = g_emaFast;
    g_emaSlow_prev = g_emaSlow;

    double a1 = 2.0 / (InpEMA_Fast + 1.0);
    double a2 = 2.0 / (InpEMA_Slow + 1.0);
    double a3 = 2.0 / (InpEMA_Trend + 1.0);

    g_emaFast = price * a1 + g_emaFast * (1.0 - a1);
    g_emaSlow = price * a2 + g_emaSlow * (1.0 - a2);
    g_emaTrend = price * a3 + g_emaTrend * (1.0 - a3);

    // EMA履歴保存（チャート描画用）
    if(InpShowEMALines && g_barCount > 0) {
        if(g_emaHistoryCount < 50) {
            g_emaHistory[g_emaHistoryCount].time = g_bars[g_barCount - 1].time;
            g_emaHistory[g_emaHistoryCount].fast = g_emaFast;
            g_emaHistory[g_emaHistoryCount].slow = g_emaSlow;
            g_emaHistory[g_emaHistoryCount].trend = g_emaTrend;
            g_emaHistoryCount++;
        } else {
            // シフト
            for(int i = 0; i < 49; i++) {
                g_emaHistory[i] = g_emaHistory[i + 1];
            }
            g_emaHistory[49].time = g_bars[g_barCount - 1].time;
            g_emaHistory[49].fast = g_emaFast;
            g_emaHistory[49].slow = g_emaSlow;
            g_emaHistory[49].trend = g_emaTrend;
        }

        // EMAライン描画
        DrawEMALines();
    }

    CalcATR();
}

//+------------------------------------------------------------------+
//| ATR計算（軽量）                                                  |
//+------------------------------------------------------------------+
void CalcATR()
{
    if(g_barCount < InpATR_Period + 1) return;

    double sum = 0;
    int start = g_barCount - InpATR_Period;

    for(int i = start; i < g_barCount - 1; i++) {
        double tr = MathMax(g_bars[i].high - g_bars[i].low,
                    MathMax(MathAbs(g_bars[i].high - g_bars[i - 1].close),
                            MathAbs(g_bars[i].low - g_bars[i - 1].close)));
        sum += tr;
    }

    g_atr = sum / InpATR_Period;
}

//+------------------------------------------------------------------+
//| シグナル検出                                                     |
//+------------------------------------------------------------------+
int DetectSignal()
{
    double diff_now = g_emaFast - g_emaSlow;
    double diff_prev = g_emaFast_prev - g_emaSlow_prev;

    int sig = 0;

    // ゴールデンクロス
    if(diff_prev <= 0 && diff_now > 0) {
        sig = 1;
    }
    // デッドクロス
    else if(diff_prev >= 0 && diff_now < 0) {
        sig = -1;
    }

    if(sig == 0) return 0;

    g_totalSignals++;

    // フィルター
    if(!PassFilters(sig)) {
        g_filteredSignals++;
        PrintFormat("Signal %s FILTERED", sig == 1 ? "BUY" : "SELL");
        return 0;
    }

    return sig;
}

//+------------------------------------------------------------------+
//| フィルターチェック（軽量）                                       |
//+------------------------------------------------------------------+
bool PassFilters(int sig)
{
    MqlTick tick;
    if(!SymbolInfoTick(_Symbol, tick)) return false;

    // スプレッド
    if(InpUseSpreadFilter) {
        double spread = tick.ask - tick.bid;
        if(spread > InpMaxSpreadUSD) {
            if(InpShowInfo) PrintFormat("  Filtered: Spread $%.2f", spread);
            return false;
        }
    }

    // ATR
    if(InpUseATRFilter && g_atr > 0) {
        if(g_atr < InpMinATR_USD || g_atr > InpMaxATR_USD) {
            if(InpShowInfo) PrintFormat("  Filtered: ATR $%.2f", g_atr);
            return false;
        }
    }

    // トレンド
    if(InpUseTrendFilter) {
        if(sig == 1 && g_emaFast < g_emaTrend) {
            if(InpShowInfo) Print("  Filtered: Buy below trend");
            return false;
        }
        if(sig == -1 && g_emaFast > g_emaTrend) {
            if(InpShowInfo) Print("  Filtered: Sell above trend");
            return false;
        }
    }

    // ボリューム
    if(InpUseVolumeFilter && g_barCount > 0) {
        double total = (double)(g_bars[g_barCount - 1].buyVol + g_bars[g_barCount - 1].sellVol);
        if(total > 0) {
            double buyRatio = (double)g_bars[g_barCount - 1].buyVol / total;
            double sellRatio = (double)g_bars[g_barCount - 1].sellVol / total;

            if(sig == 1 && buyRatio < InpMinVolumeDelta) {
                if(InpShowInfo) PrintFormat("  Filtered: Buy vol %.1f%%", buyRatio * 100);
                return false;
            }
            if(sig == -1 && sellRatio < InpMinVolumeDelta) {
                if(InpShowInfo) PrintFormat("  Filtered: Sell vol %.1f%%", sellRatio * 100);
                return false;
            }
        }
    }

    // 時間
    if(InpUseTimeFilter) {
        MqlDateTime dt;
        TimeToStruct(TimeGMT(), dt);
        if(dt.hour < InpStartHour || dt.hour >= InpEndHour) {
            if(InpShowInfo) PrintFormat("  Filtered: Hour %d", dt.hour);
            return false;
        }
    }

    return true;
}

//+------------------------------------------------------------------+
//| シグナル処理                                                     |
//+------------------------------------------------------------------+
void ProcessSignal(int sig)
{
    // 取引間隔チェック
    if(g_lastTradeTime > 0) {
        int elapsed = (int)(TimeCurrent() - g_lastTradeTime);
        if(elapsed < InpMinTradeIntervalSec) {
            if(InpShowInfo) PrintFormat("  Too soon: %ds", elapsed);
            return;
        }
    }

    // 既存ポジション決済
    if(g_ticket > 0 && g_direction != sig) {
        ClosePosition();
    }

    // 同方向ならスキップ
    if(g_direction == sig) {
        if(InpShowInfo) Print("  Already in position");
        return;
    }

    OpenPosition(sig);
}

//+------------------------------------------------------------------+
//| ポジションオープン                                               |
//+------------------------------------------------------------------+
void OpenPosition(int sig)
{
    MqlTick tick;
    if(!SymbolInfoTick(_Symbol, tick)) return;

    double price = (sig == 1) ? tick.ask : tick.bid;
    double sl = 0, tp = 0;

    // SL/TP計算（シンプル）
    if(InpSL_USD > 0) {
        sl = (sig == 1) ? price - InpSL_USD : price + InpSL_USD;
        sl = NormalizeDouble(sl, g_digits);
    }

    if(InpTP_USD > 0) {
        tp = (sig == 1) ? price + InpTP_USD : price - InpTP_USD;
        tp = NormalizeDouble(tp, g_digits);
    }

    bool result;
    if(sig == 1) {
        result = g_trade.Buy(InpFixedLots, _Symbol, 0, sl, tp, InpComment);
    } else {
        result = g_trade.Sell(InpFixedLots, _Symbol, 0, sl, tp, InpComment);
    }

    if(result) {
        g_ticket = g_trade.ResultOrder();
        g_direction = sig;
        g_lastTradeTime = TimeCurrent();

        Print("========================================");
        PrintFormat(">>> ORDER EXECUTED! <<<");
        PrintFormat("Type: %s | Lots: %.4f", sig == 1 ? "BUY" : "SELL", InpFixedLots);
        PrintFormat("Price: $%.2f | SL: $%.2f | TP: $%.2f", price, sl, tp);
        PrintFormat("Ticket: %I64u", g_ticket);
        Print("========================================");
    } else {
        Print("========================================");
        PrintFormat(">>> ORDER FAILED! <<<");
        PrintFormat("Error: %d - %s", g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
        Print("========================================");
    }
}

//+------------------------------------------------------------------+
//| ポジションクローズ                                               |
//+------------------------------------------------------------------+
void ClosePosition()
{
    if(g_ticket == 0) return;

    if(!PositionSelectByTicket(g_ticket)) {
        CheckClosed();
        return;
    }

    double pnl = PositionGetDouble(POSITION_PROFIT);

    if(g_trade.PositionClose(g_ticket)) {
        PrintFormat("[CLOSE] Ticket:%I64u | P/L:$%.2f", g_ticket, pnl);

        g_totalTrades++;
        if(pnl > 0) g_wins++;
        g_profit += pnl;

        g_ticket = 0;
        g_direction = 0;
    }
}

//+------------------------------------------------------------------+
//| 決済済みチェック                                                 |
//+------------------------------------------------------------------+
void CheckClosed()
{
    if(g_ticket == 0) return;

    if(!PositionSelectByTicket(g_ticket)) {
        // SL/TPで決済済み
        if(HistorySelectByPosition(g_ticket)) {
            int deals = HistoryDealsTotal();
            for(int i = deals - 1; i >= 0; i--) {
                ulong dt = HistoryDealGetTicket(i);
                if(dt == 0) continue;

                if(HistoryDealGetInteger(dt, DEAL_POSITION_ID) == g_ticket) {
                    double pnl = HistoryDealGetDouble(dt, DEAL_PROFIT);

                    PrintFormat("[AUTO CLOSE] Ticket:%I64u | P/L:$%.2f", g_ticket, pnl);

                    g_totalTrades++;
                    if(pnl > 0) g_wins++;
                    g_profit += pnl;

                    g_ticket = 0;
                    g_direction = 0;
                    break;
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| トレイリング                                                     |
//+------------------------------------------------------------------+
void UpdateTrailing()
{
    if(!PositionSelectByTicket(g_ticket)) {
        CheckClosed();
        return;
    }

    double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
    double current_sl = PositionGetDouble(POSITION_SL);
    double current_tp = PositionGetDouble(POSITION_TP);

    MqlTick tick;
    if(!SymbolInfoTick(_Symbol, tick)) return;

    ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

    double new_sl = 0;
    bool update = false;

    if(type == POSITION_TYPE_BUY) {
        double profit_usd = tick.bid - open_price;

        if(profit_usd >= InpTrailStart_USD) {
            new_sl = tick.bid - InpTrailStep_USD;
            new_sl = NormalizeDouble(new_sl, g_digits);

            if(new_sl > current_sl + SymbolInfoDouble(_Symbol, SYMBOL_POINT)) {
                update = true;
            }
        }
    } else {
        double profit_usd = open_price - tick.ask;

        if(profit_usd >= InpTrailStart_USD) {
            new_sl = tick.ask + InpTrailStep_USD;
            new_sl = NormalizeDouble(new_sl, g_digits);

            if(current_sl == 0 || new_sl < current_sl - SymbolInfoDouble(_Symbol, SYMBOL_POINT)) {
                update = true;
            }
        }
    }

    if(update) {
        g_trade.PositionModify(g_ticket, new_sl, current_tp);
    }
}

//+------------------------------------------------------------------+
//| 状態表示                                                         |
//+------------------------------------------------------------------+
void PrintStatus()
{
    MqlTick tick;
    SymbolInfoTick(_Symbol, tick);

    double spread = tick.ask - tick.bid;

    PrintFormat("[STATUS] Bars:%d | Signals:%d | Filtered:%d",
                g_barCount, g_totalSignals, g_filteredSignals);
    PrintFormat("  Price:$%.2f | Fast:$%.2f | Slow:$%.2f | Diff:$%.2f",
                tick.bid, g_emaFast, g_emaSlow, g_emaFast - g_emaSlow);
    PrintFormat("  ATR:$%.2f | Spread:$%.2f", g_atr, spread);
    PrintFormat("  Trades:%d | Wins:%d | P/L:$%.2f", g_totalTrades, g_wins, g_profit);
}

//+------------------------------------------------------------------+
//| EMAライン描画                                                    |
//+------------------------------------------------------------------+
void DrawEMALines()
{
    if(g_emaHistoryCount < 2) return;

    // Fast EMAライン（シアン）
    if(InpShowFastEMA) {
        for(int i = 0; i < g_emaHistoryCount - 1; i++) {
            string nameFast = "BTC_EMA_Fast_" + IntegerToString(i);

            if(ObjectFind(0, nameFast) >= 0) {
                ObjectDelete(0, nameFast);
            }

            ObjectCreate(0, nameFast, OBJ_TREND, 0,
                         g_emaHistory[i].time, g_emaHistory[i].fast,
                         g_emaHistory[i + 1].time, g_emaHistory[i + 1].fast);
            ObjectSetInteger(0, nameFast, OBJPROP_COLOR, clrAqua);
            ObjectSetInteger(0, nameFast, OBJPROP_WIDTH, 2);
            ObjectSetInteger(0, nameFast, OBJPROP_RAY_RIGHT, false);
            ObjectSetInteger(0, nameFast, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(0, nameFast, OBJPROP_BACK, true);
        }
    } else {
        // Fast EMA非表示の場合は削除
        ObjectsDeleteAll(0, "BTC_EMA_Fast_");
    }

    // Slow EMAライン（マゼンタ）
    if(InpShowSlowEMA) {
        for(int i = 0; i < g_emaHistoryCount - 1; i++) {
            string nameSlow = "BTC_EMA_Slow_" + IntegerToString(i);

            if(ObjectFind(0, nameSlow) >= 0) {
                ObjectDelete(0, nameSlow);
            }

            ObjectCreate(0, nameSlow, OBJ_TREND, 0,
                         g_emaHistory[i].time, g_emaHistory[i].slow,
                         g_emaHistory[i + 1].time, g_emaHistory[i + 1].slow);
            ObjectSetInteger(0, nameSlow, OBJPROP_COLOR, clrMagenta);
            ObjectSetInteger(0, nameSlow, OBJPROP_WIDTH, 2);
            ObjectSetInteger(0, nameSlow, OBJPROP_RAY_RIGHT, false);
            ObjectSetInteger(0, nameSlow, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(0, nameSlow, OBJPROP_BACK, true);
        }
    } else {
        // Slow EMA非表示の場合は削除
        ObjectsDeleteAll(0, "BTC_EMA_Slow_");
    }

    // Trend EMAライン（イエロー）
    if(InpShowTrendEMA) {
        for(int i = 0; i < g_emaHistoryCount - 1; i++) {
            string nameTrend = "BTC_EMA_Trend_" + IntegerToString(i);

            if(ObjectFind(0, nameTrend) >= 0) {
                ObjectDelete(0, nameTrend);
            }

            ObjectCreate(0, nameTrend, OBJ_TREND, 0,
                         g_emaHistory[i].time, g_emaHistory[i].trend,
                         g_emaHistory[i + 1].time, g_emaHistory[i + 1].trend);
            ObjectSetInteger(0, nameTrend, OBJPROP_COLOR, clrYellow);
            ObjectSetInteger(0, nameTrend, OBJPROP_WIDTH, 2);
            ObjectSetInteger(0, nameTrend, OBJPROP_RAY_RIGHT, false);
            ObjectSetInteger(0, nameTrend, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(0, nameTrend, OBJPROP_BACK, true);
        }
    } else {
        // Trend EMA非表示の場合は削除
        ObjectsDeleteAll(0, "BTC_EMA_Trend_");
    }

    // チャート再描画
    ChartRedraw();
}

//+------------------------------------------------------------------+
//| パネル作成                                                       |
//+------------------------------------------------------------------+
void CreatePanel()
{
    int width = 320;
    int height = 280;

    // 背景
    ObjectCreate(0, "BTC_Panel_BG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
    ObjectSetInteger(0, "BTC_Panel_BG", OBJPROP_CORNER, CORNER_LEFT_UPPER);
    ObjectSetInteger(0, "BTC_Panel_BG", OBJPROP_XDISTANCE, 10);
    ObjectSetInteger(0, "BTC_Panel_BG", OBJPROP_YDISTANCE, 25);
    ObjectSetInteger(0, "BTC_Panel_BG", OBJPROP_XSIZE, width);
    ObjectSetInteger(0, "BTC_Panel_BG", OBJPROP_YSIZE, height);
    ObjectSetInteger(0, "BTC_Panel_BG", OBJPROP_BGCOLOR, C'10,10,20');
    ObjectSetInteger(0, "BTC_Panel_BG", OBJPROP_BORDER_TYPE, BORDER_FLAT);
    ObjectSetInteger(0, "BTC_Panel_BG", OBJPROP_COLOR, clrOrange);
    ObjectSetInteger(0, "BTC_Panel_BG", OBJPROP_WIDTH, 2);
}

//+------------------------------------------------------------------+
//| パネル更新                                                       |
//+------------------------------------------------------------------+
void UpdatePanel()
{
    string lines[15];
    color colors[15];

    MqlTick tick;
    SymbolInfoTick(_Symbol, tick);

    double spread = tick.ask - tick.bid;
    int idx = 0;

    // タイトル
    lines[idx] = "═══ BTC LIGHT ═══";
    colors[idx++] = clrOrange;

    lines[idx] = StringFormat("%s | %ds", _Symbol, InpSecondsPerBar);
    colors[idx++] = clrWhite;

    lines[idx] = StringFormat("価格: $%.2f", tick.bid);
    colors[idx++] = clrWhite;

    lines[idx] = "──────────────";
    colors[idx++] = clrGray;

    // EMA
    lines[idx] = StringFormat("Fast: $%.2f", g_emaFast);
    colors[idx++] = clrAqua;

    lines[idx] = StringFormat("Slow: $%.2f", g_emaSlow);
    colors[idx++] = clrMagenta;

    lines[idx] = StringFormat("差分: $%.2f", g_emaFast - g_emaSlow);
    colors[idx++] = (g_emaFast > g_emaSlow) ? clrLime : clrRed;

    lines[idx] = "──────────────";
    colors[idx++] = clrGray;

    // ATR・スプレッド
    lines[idx] = StringFormat("ATR: $%.2f | Spr: $%.2f", g_atr, spread);
    colors[idx++] = clrWhite;

    lines[idx] = "──────────────";
    colors[idx++] = clrGray;

    // ポジション
    lines[idx] = StringFormat("Pos: %s",
                              g_direction == 1 ? "LONG" :
                              g_direction == -1 ? "SHORT" : "---");
    colors[idx++] = g_direction == 1 ? clrLime :
                    g_direction == -1 ? clrRed : clrGray;

    if(g_ticket > 0 && PositionSelectByTicket(g_ticket)) {
        double pnl = PositionGetDouble(POSITION_PROFIT);
        lines[idx] = StringFormat("P/L: $%.2f", pnl);
        colors[idx++] = pnl >= 0 ? clrLime : clrRed;
    } else {
        lines[idx] = "P/L: ---";
        colors[idx++] = clrGray;
    }

    lines[idx] = "──────────────";
    colors[idx++] = clrGray;

    // 統計
    double winRate = g_totalTrades > 0 ? (double)g_wins / g_totalTrades * 100 : 0;
    lines[idx] = StringFormat("取引: %dW-%dL (%.1f%%)",
                              g_wins, (g_totalTrades - g_wins), winRate);
    colors[idx++] = clrWhite;

    lines[idx] = StringFormat("総損益: $%.2f", g_profit);
    colors[idx++] = g_profit >= 0 ? clrLime : clrRed;

    // 描画
    for(int i = 0; i < ArraySize(lines); i++) {
        string objName = "BTC_Panel_L" + IntegerToString(i);

        if(ObjectFind(0, objName) < 0) {
            ObjectCreate(0, objName, OBJ_LABEL, 0, 0, 0);
            ObjectSetInteger(0, objName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
            ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, 20);
            ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, 35 + i * 18);
            ObjectSetString(0, objName, OBJPROP_FONT, "Consolas");
            ObjectSetInteger(0, objName, OBJPROP_FONTSIZE, 8);
        }

        ObjectSetString(0, objName, OBJPROP_TEXT, lines[i]);
        ObjectSetInteger(0, objName, OBJPROP_COLOR, colors[i]);
    }
}
//+------------------------------------------------------------------+
