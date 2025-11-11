//+------------------------------------------------------------------+
//|                  EMA_Cross_BTC_Light_v2.2.mq5                    |
//|              BTCUSD専用 分足ベース - 2EMAシンプル版              |
//|                                              Copyright 2024      |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024"
#property link      ""
#property version   "2.20"
#property description "BTCUSD専用 - 分足ベースEMAクロス"
#property description "v2.0: 分足ベース（より安定）"
#property description "v2.1: EMAライン全期間表示対応"
#property description "v2.2: 2EMA専用・期間表示追加"

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

input group "===== フィルター（緩め） ====="
input bool     InpUseSpreadFilter = false;   // スプレッドフィルター
input double   InpMaxSpreadUSD = 100.0;      // 最大スプレッド
input bool     InpUseATRFilter = false;      // ATRフィルター
input int      InpATR_Period = 14;           // ATR期間
input double   InpMinATR_USD = 30.0;         // 最小ATR
input double   InpMaxATR_USD = 3000.0;       // 最大ATR

input group "===== ポジション管理 ====="
input double   InpFixedLots = 0.01;          // ロット
input int      InpMinTradeIntervalMin = 5;   // 最小取引間隔（分）

input group "===== リスク管理 ====="
input double   InpSL_USD = 150.0;            // 固定SL（USD）
input double   InpTP_USD = 250.0;            // 固定TP（USD）

input group "===== その他 ====="
input int      InpMagicNumber = 77777;       // マジックナンバー
input string   InpComment = "BTC_M1";        // コメント
input bool     InpShowPanel = true;          // パネル表示

input group "===== EMAライン表示 ====="
input bool     InpShowEMALines = true;       // EMAライン表示
input bool     InpShowFastEMA = true;        // Fast EMA表示
input bool     InpShowSlowEMA = true;        // Slow EMA表示
input int      InpMaxBarsToShow = 500;       // 最大表示バー数

//+------------------------------------------------------------------+
//| グローバル変数                                                   |
//+------------------------------------------------------------------+
// EMAハンドル
int g_emaFastHandle = INVALID_HANDLE;
int g_emaSlowHandle = INVALID_HANDLE;
int g_atrHandle = INVALID_HANDLE;

// EMAバッファ
double g_emaFastBuffer[];
double g_emaSlowBuffer[];
double g_atrBuffer[];

// 計算用EMA値
double g_emaFast = 0, g_emaSlow = 0;
double g_emaFast_prev = 0, g_emaSlow_prev = 0;

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
    Print("BTC LIGHT v2.2 - STARTING (2EMAシンプル版)");
    Print("========================================");

    g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    // EMAハンドル作成
    g_emaFastHandle = iMA(_Symbol, InpTimeframe, InpEMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
    if(g_emaFastHandle == INVALID_HANDLE) {
        Print("Error: Fast EMA indicator failed");
        return INIT_FAILED;
    }

    g_emaSlowHandle = iMA(_Symbol, InpTimeframe, InpEMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
    if(g_emaSlowHandle == INVALID_HANDLE) {
        Print("Error: Slow EMA indicator failed");
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
    ArraySetAsSeries(g_emaSlowBuffer, true);
    ArraySetAsSeries(g_atrBuffer, true);

    g_trade.SetExpertMagicNumber(InpMagicNumber);
    g_trade.SetTypeFilling(ORDER_FILLING_IOC);
    g_trade.SetAsyncMode(false);

    g_lastBarTime = 0;

    // パネル作成
    if(InpShowPanel) {
        CreatePanel();
    }

    // 初期EMAライン描画（全期間）
    if(InpShowEMALines) {
        Sleep(1000);  // インジケーターデータが準備されるまで待機
        DrawAllEMALines();
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

    PrintFormat("Symbol: %s | Timeframe: %s | EMA: %d/%d",
                _Symbol, tf_name, InpEMA_Fast, InpEMA_Slow);
    PrintFormat("Lots: %.4f | SL: $%.2f | TP: $%.2f",
                InpFixedLots, InpSL_USD, InpTP_USD);
    PrintFormat("EMA表示バー数: %d", InpMaxBarsToShow);
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
    Print("BTC LIGHT v2.2 - STOPPED");
    PrintFormat("Bars: %d | Signals: %d | Filtered: %d",
                g_totalBars, g_totalSignals, g_filteredSignals);
    PrintFormat("Trades: %d | Wins: %d | P/L: $%.2f",
                g_totalTrades, g_wins, g_profit);
    Print("========================================");

    // ハンドル解放
    if(g_emaFastHandle != INVALID_HANDLE) IndicatorRelease(g_emaFastHandle);
    if(g_emaSlowHandle != INVALID_HANDLE) IndicatorRelease(g_emaSlowHandle);
    if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);

    // オブジェクト削除（より確実に）
    int total = ObjectsTotal(0, 0, -1);
    for(int i = total - 1; i >= 0; i--) {
        string name = ObjectName(0, i, 0, -1);
        if(StringFind(name, "BTC_") == 0) {
            ObjectDelete(0, name);
            Print("削除: ", name);
        }
    }
    ChartRedraw();
    Print("全オブジェクト削除完了");
}

//+------------------------------------------------------------------+
//| ティック処理                                                     |
//+------------------------------------------------------------------+
void OnTick()
{
    // 新しいバーチェック
    datetime currentBarTime = iTime(_Symbol, InpTimeframe, 0);

    if(currentBarTime == g_lastBarTime) {
        // 同じバー内
        static int tick_count = 0;
        tick_count++;

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

    // EMAライン更新（新バーのみ追加）
    if(InpShowEMALines) {
        UpdateEMALines();
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
    if(CopyBuffer(g_emaFastHandle, 0, 0, 3, g_emaFastBuffer) <= 0) {
        return false;
    }

    // Slow EMA
    if(CopyBuffer(g_emaSlowHandle, 0, 0, 3, g_emaSlowBuffer) <= 0) {
        return false;
    }

    // ATR
    if(CopyBuffer(g_atrHandle, 0, 0, 1, g_atrBuffer) <= 0) {
        return false;
    }

    g_emaFast_prev = g_emaFast;
    g_emaSlow_prev = g_emaSlow;

    g_emaFast = g_emaFastBuffer[0];
    g_emaSlow = g_emaSlowBuffer[0];

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

    if(diff_prev <= 0 && diff_now > 0) {
        sig = 1;
    }
    else if(diff_prev >= 0 && diff_now < 0) {
        sig = -1;
    }

    if(sig == 0) return 0;

    g_totalSignals++;

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

    if(InpUseSpreadFilter) {
        double spread = tick.ask - tick.bid;
        if(spread > InpMaxSpreadUSD) return false;
    }

    if(InpUseATRFilter && g_atrBuffer[0] > 0) {
        double atr = g_atrBuffer[0];
        if(atr < InpMinATR_USD || atr > InpMaxATR_USD) return false;
    }

    return true;
}

//+------------------------------------------------------------------+
//| シグナル処理                                                     |
//+------------------------------------------------------------------+
void ProcessSignal(int sig)
{
    if(g_lastTradeTime > 0) {
        int elapsed = (int)((TimeCurrent() - g_lastTradeTime) / 60);
        if(elapsed < InpMinTradeIntervalMin) {
            PrintFormat("  Too soon: %d min", elapsed);
            return;
        }
    }

    if(g_ticket > 0 && g_direction != sig) {
        ClosePosition();
    }

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
//| 全期間EMAライン描画（初回のみ）                                  |
//+------------------------------------------------------------------+
void DrawAllEMALines()
{
    Print("全期間EMAライン描画開始...");

    int bars_to_draw = MathMin(InpMaxBarsToShow, Bars(_Symbol, InpTimeframe));

    // Fast EMA
    if(InpShowFastEMA) {
        double fastBuffer[];
        ArraySetAsSeries(fastBuffer, true);
        if(CopyBuffer(g_emaFastHandle, 0, 0, bars_to_draw + 1, fastBuffer) > 0) {
            for(int i = 0; i < bars_to_draw; i++) {
                datetime time1 = iTime(_Symbol, InpTimeframe, i);
                datetime time2 = iTime(_Symbol, InpTimeframe, i + 1);
                double val1 = fastBuffer[i];
                double val2 = fastBuffer[i + 1];

                string name = "BTC_EMA_Fast_" + IntegerToString(i);
                ObjectCreate(0, name, OBJ_TREND, 0, time1, val1, time2, val2);
                ObjectSetInteger(0, name, OBJPROP_COLOR, clrAqua);
                ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
                ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
                ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
                ObjectSetInteger(0, name, OBJPROP_BACK, true);
            }
            PrintFormat("Fast EMA: %d本描画", bars_to_draw);
        }
    }

    // Slow EMA
    if(InpShowSlowEMA) {
        double slowBuffer[];
        ArraySetAsSeries(slowBuffer, true);
        if(CopyBuffer(g_emaSlowHandle, 0, 0, bars_to_draw + 1, slowBuffer) > 0) {
            for(int i = 0; i < bars_to_draw; i++) {
                datetime time1 = iTime(_Symbol, InpTimeframe, i);
                datetime time2 = iTime(_Symbol, InpTimeframe, i + 1);
                double val1 = slowBuffer[i];
                double val2 = slowBuffer[i + 1];

                string name = "BTC_EMA_Slow_" + IntegerToString(i);
                ObjectCreate(0, name, OBJ_TREND, 0, time1, val1, time2, val2);
                ObjectSetInteger(0, name, OBJPROP_COLOR, clrMagenta);
                ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
                ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
                ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
                ObjectSetInteger(0, name, OBJPROP_BACK, true);
            }
            PrintFormat("Slow EMA: %d本描画", bars_to_draw);
        }
    }

    ChartRedraw();
    Print("EMAライン描画完了");
}

//+------------------------------------------------------------------+
//| EMAライン更新（新バー追加時）                                    |
//+------------------------------------------------------------------+
void UpdateEMALines()
{
    // 古いラインを1つシフト（削除＋再描画）
    DrawAllEMALines();
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

    lines[idx] = "═══ BTC v2.2 (2EMA) ═══";
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

    lines[idx] = StringFormat("EMA設定: %d / %d", InpEMA_Fast, InpEMA_Slow);
    colors[idx++] = clrYellow;

    lines[idx] = StringFormat("Fast(%d): $%.2f", InpEMA_Fast, g_emaFast);
    colors[idx++] = clrAqua;

    lines[idx] = StringFormat("Slow(%d): $%.2f", InpEMA_Slow, g_emaSlow);
    colors[idx++] = clrMagenta;

    lines[idx] = StringFormat("差分: $%.2f", g_emaFast - g_emaSlow);
    colors[idx++] = (g_emaFast > g_emaSlow) ? clrLime : clrRed;

    lines[idx] = "──────────────";
    colors[idx++] = clrGray;

    double atr = (g_atrBuffer[0] > 0) ? g_atrBuffer[0] : 0;
    lines[idx] = StringFormat("ATR: $%.2f | Spr: $%.2f", atr, spread);
    colors[idx++] = clrWhite;

    lines[idx] = "──────────────";
    colors[idx++] = clrGray;

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

    double winRate = g_totalTrades > 0 ? (double)g_wins / g_totalTrades * 100 : 0;
    lines[idx] = StringFormat("取引: %dW-%dL (%.1f%%)",
                              g_wins, (g_totalTrades - g_wins), winRate);
    colors[idx++] = clrWhite;

    lines[idx] = StringFormat("総損益: $%.2f", g_profit);
    colors[idx++] = g_profit >= 0 ? clrLime : clrRed;

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
