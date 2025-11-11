//+------------------------------------------------------------------+
//|                  EMA_Cross_BTC_Light_v2.0.mq5                    |
//|              BTCUSD専用 分足ベースEMAクロスシステム               |
//|                                              Copyright 2024      |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024"
#property link      ""
#property version   "2.00"
#property description "BTCUSD専用 - 分足ベースEMAクロス"
#property description "v1.x: 秒足ベース"
#property description "v2.0: 分足ベース（より安定）"

#include <Trade\Trade.mqh>
CTrade g_trade;

//+------------------------------------------------------------------+
//| パラメータ（分足ベース）                                         |
//+------------------------------------------------------------------+
input group "===== 時間軸設定 ====="
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M1;  // 取引時間軸

input group "===== EMA設定（BTC最適化） ====="
input int      InpEMA_Fast = 5;              // 短期EMA
input int      InpEMA_Slow = 13;             // 長期EMA
input int      InpEMA_Trend = 34;            // トレンドEMA

input group "===== フィルター（緩め） ====="
input bool     InpUseTrendFilter = false;    // トレンドフィルター
input bool     InpUseVolumeFilter = false;   // ボリュームフィルター
input double   InpMinVolumeDelta = 0.55;     // 最小ボリューム比率
input bool     InpUseSpreadFilter = false;   // スプレッドフィルター
input double   InpMaxSpreadUSD = 100.0;      // 最大スプレッド
input bool     InpUseATRFilter = false;      // ATRフィルター
input int      InpATR_Period = 14;           // ATR期間
input double   InpMinATR_USD = 30.0;         // 最小ATR
input double   InpMaxATR_USD = 3000.0;       // 最大ATR

input group "===== 時間帯（24時間対応） ====="
input bool     InpUseTimeFilter = false;     // 時間フィルター
input int      InpStartHour = 0;             // 開始時刻（UTC）
input int      InpEndHour = 24;              // 終了時刻（UTC）

input group "===== ポジション管理 ====="
input double   InpFixedLots = 0.01;          // ロット
input int      InpMinTradeIntervalMin = 5;   // 最小取引間隔（分）

input group "===== リスク管理 ====="
input double   InpSL_USD = 150.0;            // 固定SL（USD）
input double   InpTP_USD = 250.0;            // 固定TP（USD）
input bool     InpUseTrailing = false;       // トレイリング
input double   InpTrailStart_USD = 200.0;    // トレイリング開始
input double   InpTrailStep_USD = 80.0;      // トレイリングステップ

input group "===== その他 ====="
input int      InpMagicNumber = 77777;       // マジックナンバー
input string   InpComment = "BTC_M1";        // コメント
input bool     InpShowPanel = true;          // パネル表示

input group "===== EMAライン表示 ====="
input bool     InpShowEMALines = true;       // EMAライン表示
input bool     InpShowFastEMA = true;        // Fast EMA表示
input bool     InpShowSlowEMA = true;        // Slow EMA表示
input bool     InpShowTrendEMA = false;      // Trend EMA表示

//+------------------------------------------------------------------+
//| グローバル変数                                                   |
//+------------------------------------------------------------------+
// EMAバッファ
double g_emaFastBuffer[];
double g_emaTrendBuffer[];
int g_emaFastHandle = INVALID_HANDLE;
int g_emaTrendHandle = INVALID_HANDLE;

// 計算用EMA値
double g_emaFast = 0, g_emaSlow = 0, g_emaTrend = 0;
double g_emaFast_prev = 0, g_emaSlow_prev = 0;

// ATR
int g_atrHandle = INVALID_HANDLE;
double g_atrBuffer[];

// ポジション
ulong g_ticket = 0;
int g_direction = 0;
datetime g_lastTradeTime = 0;
datetime g_lastBarTime = 0;

// 統計
int g_totalTrades = 0;
int g_wins = 0;
double g_profit = 0;

// その他
int g_digits = 0;
int g_totalBars = 0;
int g_totalSignals = 0;
int g_filteredSignals = 0;

//+------------------------------------------------------------------+
//| 初期化                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
    Print("========================================");
    Print("BTC LIGHT v2.0 - STARTING (分足ベース)");
    Print("========================================");

    g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    // EMAハンドル作成（Fast）
    g_emaFastHandle = iMA(_Symbol, InpTimeframe, InpEMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
    if(g_emaFastHandle == INVALID_HANDLE) {
        Print("Error: Fast EMA indicator failed");
        return INIT_FAILED;
    }

    // EMAハンドル作成（Trend）
    g_emaTrendHandle = iMA(_Symbol, InpTimeframe, InpEMA_Trend, 0, MODE_EMA, PRICE_CLOSE);
    if(g_emaTrendHandle == INVALID_HANDLE) {
        Print("Error: Trend EMA indicator failed");
        return INIT_FAILED;
    }

    // ATRハンドル作成
    g_atrHandle = iATR(_Symbol, InpTimeframe, InpATR_Period);
    if(g_atrHandle == INVALID_HANDLE) {
        Print("Error: ATR indicator failed");
        return INIT_FAILED;
    }

    // バッファ設定
    ArraySetAsSeries(g_emaFastBuffer, true);
    ArraySetAsSeries(g_emaTrendBuffer, true);
    ArraySetAsSeries(g_atrBuffer, true);

    g_trade.SetExpertMagicNumber(InpMagicNumber);
    g_trade.SetTypeFilling(ORDER_FILLING_IOC);
    g_trade.SetAsyncMode(false);

    g_lastBarTime = 0;

    // パネル作成
    if(InpShowPanel) {
        CreatePanel();
    }

    string tf_name = "";
    switch(InpTimeframe) {
        case PERIOD_M1: tf_name = "M1"; break;
        case PERIOD_M5: tf_name = "M5"; break;
        case PERIOD_M15: tf_name = "M15"; break;
        case PERIOD_M30: tf_name = "M30"; break;
        case PERIOD_H1: tf_name = "H1"; break;
        default: tf_name = "M1";
    }

    PrintFormat("Symbol: %s | Timeframe: %s | EMA: %d/%d/%d",
                _Symbol, tf_name, InpEMA_Fast, InpEMA_Slow, InpEMA_Trend);
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
    Print("BTC LIGHT v2.0 - STOPPED");
    PrintFormat("Bars: %d | Signals: %d | Filtered: %d",
                g_totalBars, g_totalSignals, g_filteredSignals);
    PrintFormat("Trades: %d | Wins: %d | P/L: $%.2f",
                g_totalTrades, g_wins, g_profit);
    Print("========================================");

    // ハンドル解放
    if(g_emaFastHandle != INVALID_HANDLE) IndicatorRelease(g_emaFastHandle);
    if(g_emaTrendHandle != INVALID_HANDLE) IndicatorRelease(g_emaTrendHandle);
    if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);

    // オブジェクト削除
    ObjectsDeleteAll(0, "BTC_");
}

//+------------------------------------------------------------------+
//| ティック処理                                                     |
//+------------------------------------------------------------------+
void OnTick()
{
    // 新しいバーチェック
    datetime currentBarTime = iTime(_Symbol, InpTimeframe, 0);

    if(currentBarTime == g_lastBarTime) {
        // 同じバー内 - トレイリングとパネル更新のみ
        static int tick_count = 0;
        tick_count++;

        if(InpUseTrailing && g_ticket > 0 && tick_count % 10 == 0) {
            UpdateTrailing();
        }

        if(InpShowPanel && tick_count % 30 == 0) {
            UpdatePanel();
        }

        return;
    }

    // 新バー確定
    g_lastBarTime = currentBarTime;
    g_totalBars++;

    // EMAデータ取得
    if(!GetEMAData()) {
        return;
    }

    // シグナル検出
    int signal = DetectSignal();
    if(signal != 0) {
        PrintFormat(">>> SIGNAL: %s | Time: %s <<<",
                    signal == 1 ? "BUY" : "SELL",
                    TimeToString(currentBarTime, TIME_DATE|TIME_MINUTES));
        ProcessSignal(signal);
    }

    // EMAライン描画
    if(InpShowEMALines) {
        DrawEMALines();
    }

    // パネル更新
    if(InpShowPanel) {
        UpdatePanel();
    }

    // ポジションチェック
    if(g_ticket > 0) {
        CheckClosed();
    }
}

//+------------------------------------------------------------------+
//| EMAデータ取得                                                    |
//+------------------------------------------------------------------+
bool GetEMAData()
{
    // Fast EMA
    if(CopyBuffer(g_emaFastHandle, 0, 0, InpEMA_Slow + 2, g_emaFastBuffer) <= 0) {
        return false;
    }

    // Trend EMA
    if(CopyBuffer(g_emaTrendHandle, 0, 0, 2, g_emaTrendBuffer) <= 0) {
        return false;
    }

    // ATR
    if(CopyBuffer(g_atrHandle, 0, 0, 1, g_atrBuffer) <= 0) {
        return false;
    }

    // Slow EMA計算（Fast EMAから）
    g_emaFast_prev = g_emaFast;
    g_emaSlow_prev = g_emaSlow;

    g_emaFast = g_emaFastBuffer[0];
    g_emaTrend = g_emaTrendBuffer[0];

    // Slow EMAを手動計算（Fastバッファから）
    double sum = 0;
    for(int i = 0; i < InpEMA_Slow; i++) {
        sum += g_emaFastBuffer[i];
    }
    g_emaSlow = sum / InpEMA_Slow;

    return true;
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
//| フィルターチェック                                               |
//+------------------------------------------------------------------+
bool PassFilters(int sig)
{
    MqlTick tick;
    if(!SymbolInfoTick(_Symbol, tick)) return false;

    // スプレッド
    if(InpUseSpreadFilter) {
        double spread = tick.ask - tick.bid;
        if(spread > InpMaxSpreadUSD) return false;
    }

    // ATR
    if(InpUseATRFilter && g_atrBuffer[0] > 0) {
        double atr = g_atrBuffer[0];
        if(atr < InpMinATR_USD || atr > InpMaxATR_USD) return false;
    }

    // トレンド
    if(InpUseTrendFilter) {
        if(sig == 1 && g_emaFast < g_emaTrend) return false;
        if(sig == -1 && g_emaFast > g_emaTrend) return false;
    }

    // ボリューム
    if(InpUseVolumeFilter) {
        long tickVol[];
        if(CopyTickVolume(_Symbol, InpTimeframe, 0, 1, tickVol) > 0) {
            if(tickVol[0] == 0) return false;
        }
    }

    // 時間
    if(InpUseTimeFilter) {
        MqlDateTime dt;
        TimeToStruct(TimeGMT(), dt);
        if(dt.hour < InpStartHour || dt.hour >= InpEndHour) return false;
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
        int elapsed = (int)((TimeCurrent() - g_lastTradeTime) / 60);
        if(elapsed < InpMinTradeIntervalMin) {
            PrintFormat("  Too soon: %d min", elapsed);
            return;
        }
    }

    // 既存ポジション決済
    if(g_ticket > 0 && g_direction != sig) {
        ClosePosition();
    }

    // 同方向ならスキップ
    if(g_direction == sig) {
        Print("  Already in position");
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
//| EMAライン描画                                                    |
//+------------------------------------------------------------------+
void DrawEMALines()
{
    // Fast EMA
    if(InpShowFastEMA) {
        for(int i = 0; i < 50; i++) {
            double val1 = g_emaFastBuffer[i];
            double val2 = g_emaFastBuffer[i + 1];
            datetime time1 = iTime(_Symbol, InpTimeframe, i);
            datetime time2 = iTime(_Symbol, InpTimeframe, i + 1);

            string name = "BTC_EMA_Fast_" + IntegerToString(i);
            if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);

            ObjectCreate(0, name, OBJ_TREND, 0, time1, val1, time2, val2);
            ObjectSetInteger(0, name, OBJPROP_COLOR, clrAqua);
            ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
            ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
            ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(0, name, OBJPROP_BACK, true);
        }
    } else {
        ObjectsDeleteAll(0, "BTC_EMA_Fast_");
    }

    // Trend EMA
    if(InpShowTrendEMA) {
        for(int i = 0; i < 50; i++) {
            double val1 = g_emaTrendBuffer[i];
            double val2 = g_emaTrendBuffer[i + 1];
            datetime time1 = iTime(_Symbol, InpTimeframe, i);
            datetime time2 = iTime(_Symbol, InpTimeframe, i + 1);

            string name = "BTC_EMA_Trend_" + IntegerToString(i);
            if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);

            ObjectCreate(0, name, OBJ_TREND, 0, time1, val1, time2, val2);
            ObjectSetInteger(0, name, OBJPROP_COLOR, clrYellow);
            ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
            ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
            ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(0, name, OBJPROP_BACK, true);
        }
    } else {
        ObjectsDeleteAll(0, "BTC_EMA_Trend_");
    }

    ChartRedraw();
}

//+------------------------------------------------------------------+
//| パネル作成                                                       |
//+------------------------------------------------------------------+
void CreatePanel()
{
    int width = 320;
    int height = 280;

    ObjectCreate(0, "BTC_Panel_BG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
    ObjectSetInteger(0, "BTC_Panel_BG", OBJPROP_CORNER, CORNER_LEFT_UPPER);
    ObjectSetInteger(0, "BTC_Panel_BG", OBJPROP_XDISTANCE, 10);
    ObjectSetInteger(0, "BTC_Panel_BG", OBJPROP_YDISTANCE, 25);
    ObjectSetInteger(0, "BTC_Panel_BG", OBJPROP_XSIZE, width);
    ObjectSetInteger(0, "BTC_Panel_BG", OBJPROP_YSIZE, height);
    ObjectSetInteger(0, "BTC_Panel_BG", OBJPROP_BGCOLOR, C'10,10,20');
    ObjectSetInteger(0, "BTC_Panel_BG", OBJPROP_BORDER_TYPE, BORDER_FLAT);
    ObjectSetInteger(0, "BTC_Panel_BG", OBJPROP_COLOR, clrDodgerBlue);
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
    lines[idx] = "═══ BTC v2.0 (M1) ═══";
    colors[idx++] = clrDodgerBlue;

    string tf_str = "";
    switch(InpTimeframe) {
        case PERIOD_M1: tf_str = "M1"; break;
        case PERIOD_M5: tf_str = "M5"; break;
        case PERIOD_M15: tf_str = "M15"; break;
        default: tf_str = "M1";
    }

    lines[idx] = StringFormat("%s | %s", _Symbol, tf_str);
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
    double atr = (g_atrBuffer[0] > 0) ? g_atrBuffer[0] : 0;
    lines[idx] = StringFormat("ATR: $%.2f | Spr: $%.2f", atr, spread);
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
