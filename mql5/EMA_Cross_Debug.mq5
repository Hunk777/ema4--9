//+------------------------------------------------------------------+
//|                        EMA_Cross_Debug.mq5                       |
//|                     デバッグ診断バージョン                        |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024"
#property link      ""
#property version   "1.00"
#property description "エントリーされない原因を診断"

#include <Trade\Trade.mqh>
CTrade g_trade;

//+------------------------------------------------------------------+
//| 秒足バー構造体                                                   |
//+------------------------------------------------------------------+
struct SSecondBar
{
    datetime time;
    double open;
    double high;
    double low;
    double close;
    long volume;
    long buyVolume;
    long sellVolume;

    void Reset(datetime t, double price)
    {
        time = t;
        open = high = low = close = price;
        volume = 0;
        buyVolume = sellVolume = 0;
    }

    void Update(double price, long vol, bool isBuy)
    {
        if(price > high) high = price;
        if(price < low) low = price;
        close = price;
        volume += vol;
        if(isBuy) buyVolume += vol;
        else sellVolume += vol;
    }
};

//+------------------------------------------------------------------+
//| パラメータ                                                       |
//+------------------------------------------------------------------+
input group "===== 秒足設定 ====="
input int      InpSecondsPerBar = 10;

input group "===== EMA設定 ====="
input int      InpEMA_Fast = 3;
input int      InpEMA_Slow = 8;
input int      InpEMA_Trend = 21;

input group "===== シグナルフィルター ====="
input double   InpMinCrossStrength = 0.5;
input bool     InpUseTrendFilter = true;
input bool     InpUseVolumeFilter = true;
input double   InpMinVolumeDelta = 0.6;
input bool     InpUseSpreadFilter = true;
input double   InpMaxSpreadPips = 1.0;
input bool     InpUseATRFilter = true;
input int      InpATR_Period = 20;
input double   InpMinATR_Pips = 1.0;
input double   InpMaxATR_Pips = 50.0;

input group "===== 時間帯フィルター ====="
input bool     InpUseTimeFilter = true;
input int      InpStartHour = 8;
input int      InpEndHour = 21;

input group "===== リスク管理 ====="
input double   InpFixedLots = 0.01;
input double   InpMaxDailyLoss = 3.0;
input int      InpMaxDailyTrades = 20;
input int      InpMaxConsecLosses = 5;

input group "===== その他 ====="
input int      InpMagicNumber = 99999;
input string   InpComment = "DEBUG";

//+------------------------------------------------------------------+
//| グローバル変数                                                   |
//+------------------------------------------------------------------+
SSecondBar g_bars[50];
int g_barCount = 0;
datetime g_currentBarTime = 0;
SSecondBar g_currentBar;

double g_emaFast = 0, g_emaSlow = 0, g_emaTrend = 0;
double g_emaFast_prev = 0, g_emaSlow_prev = 0;
bool g_emaInitialized = false;

double g_atr = 0;
double g_pointMultiplier = 1.0;
int g_digits = 0;

double g_lastBid = 0;
int g_totalTicks = 0;
int g_totalBars = 0;
int g_totalSignals = 0;
int g_filteredSignals = 0;

datetime g_lastDayCheck = 0;
double g_dailyStartBalance = 0;
int g_dailyTrades = 0;
int g_consecutiveLosses = 0;

// デバッグカウンター
int g_filterReasons[10];
string g_filterNames[10] = {
    "CrossStrength",
    "Spread",
    "ATR",
    "Trend",
    "Volume",
    "TimeFilter",
    "RiskManagement",
    "TradeInterval",
    "AlreadyInPosition",
    "Other"
};

//+------------------------------------------------------------------+
//| 初期化                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
    Print("========================================");
    Print("EMA CROSS DEBUG MODE - STARTING");
    Print("========================================");

    g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    g_pointMultiplier = (g_digits == 5 || g_digits == 3) ? 10.0 : 1.0;

    g_trade.SetExpertMagicNumber(InpMagicNumber);
    g_trade.SetTypeFilling(ORDER_FILLING_FOK);

    MqlTick tick;
    if(SymbolInfoTick(_Symbol, tick)) {
        g_currentBarTime = TimeCurrent();
        g_currentBarTime -= g_currentBarTime % InpSecondsPerBar;
        g_currentBar.Reset(g_currentBarTime, tick.bid);
        g_lastBid = tick.bid;
    }

    InitializeEMA();

    g_dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    g_lastDayCheck = TimeCurrent();

    ArrayInitialize(g_filterReasons, 0);

    PrintFormat("Symbol: %s | Digits: %d | Point: %.5f | Multiplier: %.0f",
                _Symbol, g_digits, _Point, g_pointMultiplier);
    PrintFormat("EMA Periods: %d / %d / %d", InpEMA_Fast, InpEMA_Slow, InpEMA_Trend);
    Print("========================================");
    Print("WAITING FOR SIGNALS...");
    Print("========================================");

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| 終了処理                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    Print("========================================");
    Print("DEBUG STATISTICS");
    Print("========================================");
    PrintFormat("Total Ticks: %d", g_totalTicks);
    PrintFormat("Total Bars Created: %d", g_totalBars);
    PrintFormat("Total Signals Detected: %d", g_totalSignals);
    PrintFormat("Filtered Signals: %d", g_filteredSignals);
    Print("----------------------------------------");
    Print("FILTER BREAKDOWN:");
    for(int i = 0; i < 10; i++) {
        if(g_filterReasons[i] > 0) {
            PrintFormat("  %s: %d times", g_filterNames[i], g_filterReasons[i]);
        }
    }
    Print("========================================");
}

//+------------------------------------------------------------------+
//| ティック処理                                                     |
//+------------------------------------------------------------------+
void OnTick()
{
    g_totalTicks++;

    MqlTick tick;
    if(!SymbolInfoTick(_Symbol, tick)) return;

    datetime currentTime = TimeCurrent();
    datetime barTime = currentTime - (currentTime % InpSecondsPerBar);

    // 新しいバー
    if(barTime > g_currentBarTime) {
        // 前のバーを保存
        if(g_barCount < 50) {
            g_bars[g_barCount] = g_currentBar;
            g_barCount++;
        } else {
            // シフト
            for(int i = 0; i < 49; i++) {
                g_bars[i] = g_bars[i + 1];
            }
            g_bars[49] = g_currentBar;
        }

        g_currentBarTime = barTime;
        g_currentBar.Reset(barTime, tick.bid);
        g_totalBars++;

        CalculateEMA();

        // 10バーに1回、状態を出力
        if(g_totalBars % 10 == 0) {
            PrintStatus();
        }

        // シグナル検出
        if(g_emaInitialized && g_barCount >= 2) {
            int signal = DetectSignal();
            if(signal != 0) {
                PrintFormat(">>> SIGNAL DETECTED: %s <<<", signal == 1 ? "BUY" : "SELL");
                ProcessSignal(signal);
            }
        }
    } else {
        bool isBuy = (tick.bid >= g_lastBid);
        g_currentBar.Update(tick.bid, tick.volume, isBuy);
    }

    g_lastBid = tick.bid;
}

//+------------------------------------------------------------------+
//| EMA初期化                                                        |
//+------------------------------------------------------------------+
void InitializeEMA()
{
    double close[];
    ArraySetAsSeries(close, true);

    int copied = CopyClose(_Symbol, PERIOD_M1, 0, InpEMA_Trend * 2, close);

    if(copied < InpEMA_Trend) {
        Print("WARNING: Not enough history data");
        if(copied > 0) {
            g_emaFast = close[0];
            g_emaSlow = close[0];
            g_emaTrend = close[0];
        }
        return;
    }

    double sumFast = 0, sumSlow = 0, sumTrend = 0;

    for(int i = 0; i < InpEMA_Fast; i++) sumFast += close[i];
    g_emaFast = sumFast / InpEMA_Fast;

    for(int i = 0; i < InpEMA_Slow; i++) sumSlow += close[i];
    g_emaSlow = sumSlow / InpEMA_Slow;

    for(int i = 0; i < InpEMA_Trend; i++) sumTrend += close[i];
    g_emaTrend = sumTrend / InpEMA_Trend;

    g_emaFast_prev = g_emaFast;
    g_emaSlow_prev = g_emaSlow;

    g_emaInitialized = true;

    PrintFormat("EMA Initialized: Fast=%.5f, Slow=%.5f, Trend=%.5f",
                g_emaFast, g_emaSlow, g_emaTrend);
}

//+------------------------------------------------------------------+
//| EMA計算                                                          |
//+------------------------------------------------------------------+
void CalculateEMA()
{
    if(g_barCount == 0) return;

    double price = g_bars[g_barCount - 1].close;

    g_emaFast_prev = g_emaFast;
    g_emaSlow_prev = g_emaSlow;

    double alphaFast = 2.0 / (InpEMA_Fast + 1.0);
    double alphaSlow = 2.0 / (InpEMA_Slow + 1.0);
    double alphaTrend = 2.0 / (InpEMA_Trend + 1.0);

    g_emaFast = price * alphaFast + g_emaFast * (1.0 - alphaFast);
    g_emaSlow = price * alphaSlow + g_emaSlow * (1.0 - alphaSlow);
    g_emaTrend = price * alphaTrend + g_emaTrend * (1.0 - alphaTrend);

    CalculateATR();
}

//+------------------------------------------------------------------+
//| ATR計算                                                          |
//+------------------------------------------------------------------+
void CalculateATR()
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
    double diff_current = g_emaFast - g_emaSlow;
    double diff_prev = g_emaFast_prev - g_emaSlow_prev;

    double crossStrength = MathAbs(diff_current) / _Point / g_pointMultiplier;

    PrintFormat("[CROSS CHECK] Current Diff: %.5f (%.2fp) | Prev Diff: %.5f",
                diff_current, crossStrength, diff_prev);

    if(crossStrength < InpMinCrossStrength) {
        PrintFormat("  -> Cross strength too weak: %.2f < %.2f",
                    crossStrength, InpMinCrossStrength);
        g_filterReasons[0]++;
        return 0;
    }

    int signal = 0;

    if(diff_prev <= 0 && diff_current > 0) {
        signal = 1;
        PrintFormat("  -> GOLDEN CROSS DETECTED!");
    }
    else if(diff_prev >= 0 && diff_current < 0) {
        signal = -1;
        PrintFormat("  -> DEAD CROSS DETECTED!");
    }

    if(signal == 0) {
        return 0;
    }

    g_totalSignals++;

    return signal;
}

//+------------------------------------------------------------------+
//| シグナル処理                                                     |
//+------------------------------------------------------------------+
void ProcessSignal(int signal)
{
    Print("========================================");
    PrintFormat("PROCESSING %s SIGNAL", signal == 1 ? "BUY" : "SELL");
    Print("========================================");

    // フィルターチェック
    if(!PassFilters(signal)) {
        Print(">>> SIGNAL FILTERED OUT <<<");
        g_filteredSignals++;
        return;
    }

    Print(">>> ALL FILTERS PASSED! <<<");

    // リスク管理チェック
    if(!CheckRiskManagement()) {
        Print(">>> BLOCKED BY RISK MANAGEMENT <<<");
        g_filterReasons[6]++;
        g_filteredSignals++;
        return;
    }

    Print(">>> RISK MANAGEMENT OK <<<");
    Print(">>> OPENING POSITION... <<<");

    OpenPosition(signal);
}

//+------------------------------------------------------------------+
//| フィルターチェック                                               |
//+------------------------------------------------------------------+
bool PassFilters(int signal)
{
    MqlTick tick;
    if(!SymbolInfoTick(_Symbol, tick)) return false;

    Print("--- FILTER CHECK ---");

    // スプレッドフィルター
    if(InpUseSpreadFilter) {
        double spread = (tick.ask - tick.bid) / _Point / g_pointMultiplier;
        PrintFormat("Spread: %.2f pips (Max: %.2f)", spread, InpMaxSpreadPips);
        if(spread > InpMaxSpreadPips) {
            Print("  -> FILTERED: Spread too high");
            g_filterReasons[1]++;
            return false;
        }
    }

    // ATRフィルター
    if(InpUseATRFilter && g_atr > 0) {
        double atrPips = g_atr / _Point / g_pointMultiplier;
        PrintFormat("ATR: %.2f pips (Range: %.2f - %.2f)",
                    atrPips, InpMinATR_Pips, InpMaxATR_Pips);
        if(atrPips < InpMinATR_Pips || atrPips > InpMaxATR_Pips) {
            Print("  -> FILTERED: ATR out of range");
            g_filterReasons[2]++;
            return false;
        }
    }

    // トレンドフィルター
    if(InpUseTrendFilter) {
        PrintFormat("Trend Check: Fast=%.5f, Trend=%.5f", g_emaFast, g_emaTrend);
        if(signal == 1 && g_emaFast < g_emaTrend) {
            Print("  -> FILTERED: Buy but Fast EMA below Trend EMA");
            g_filterReasons[3]++;
            return false;
        }
        if(signal == -1 && g_emaFast > g_emaTrend) {
            Print("  -> FILTERED: Sell but Fast EMA above Trend EMA");
            g_filterReasons[3]++;
            return false;
        }
    }

    // ボリュームフィルター
    if(InpUseVolumeFilter && g_barCount > 0) {
        SSecondBar bar = g_bars[g_barCount - 1];
        double totalVol = (double)(bar.buyVolume + bar.sellVolume);
        if(totalVol > 0) {
            double buyRatio = (double)bar.buyVolume / totalVol;
            double sellRatio = (double)bar.sellVolume / totalVol;

            PrintFormat("Volume: Buy=%.2f%% Sell=%.2f%% (MinDelta: %.2f%%)",
                        buyRatio * 100, sellRatio * 100, InpMinVolumeDelta * 100);

            if(signal == 1 && buyRatio < InpMinVolumeDelta) {
                Print("  -> FILTERED: Buy volume too low");
                g_filterReasons[4]++;
                return false;
            }
            if(signal == -1 && sellRatio < InpMinVolumeDelta) {
                Print("  -> FILTERED: Sell volume too low");
                g_filterReasons[4]++;
                return false;
            }
        }
    }

    // 時間帯フィルター
    if(InpUseTimeFilter) {
        MqlDateTime dt;
        TimeToStruct(TimeCurrent(), dt);
        PrintFormat("Time: %02d:00 (Range: %d:00 - %d:00)", dt.hour, InpStartHour, InpEndHour);
        if(dt.hour < InpStartHour || dt.hour >= InpEndHour) {
            Print("  -> FILTERED: Outside trading hours");
            g_filterReasons[5]++;
            return false;
        }
    }

    Print("  -> ALL FILTERS PASSED!");
    return true;
}

//+------------------------------------------------------------------+
//| リスク管理チェック                                               |
//+------------------------------------------------------------------+
bool CheckRiskManagement()
{
    Print("--- RISK MANAGEMENT CHECK ---");

    // 日次損失チェック
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    if(g_dailyStartBalance > 0) {
        double dailyLossPct = (g_dailyStartBalance - balance) / g_dailyStartBalance * 100;
        PrintFormat("Daily Loss: %.2f%% (Max: %.2f%%)", dailyLossPct, InpMaxDailyLoss);
        if(dailyLossPct >= InpMaxDailyLoss) {
            Print("  -> BLOCKED: Daily loss limit reached");
            return false;
        }
    }

    // 日次取引数チェック
    PrintFormat("Daily Trades: %d (Max: %d)", g_dailyTrades, InpMaxDailyTrades);
    if(g_dailyTrades >= InpMaxDailyTrades) {
        Print("  -> BLOCKED: Daily trade limit reached");
        return false;
    }

    // 連敗チェック
    PrintFormat("Consecutive Losses: %d (Max: %d)", g_consecutiveLosses, InpMaxConsecLosses);
    if(g_consecutiveLosses >= InpMaxConsecLosses) {
        Print("  -> BLOCKED: Consecutive loss limit reached");
        return false;
    }

    Print("  -> RISK MANAGEMENT PASSED!");
    return true;
}

//+------------------------------------------------------------------+
//| ポジションオープン                                               |
//+------------------------------------------------------------------+
void OpenPosition(int signal)
{
    MqlTick tick;
    if(!SymbolInfoTick(_Symbol, tick)) return;

    double entryPrice = (signal == 1) ? tick.ask : tick.bid;

    bool result;
    if(signal == 1) {
        result = g_trade.Buy(InpFixedLots, _Symbol, 0, 0, 0, InpComment);
    } else {
        result = g_trade.Sell(InpFixedLots, _Symbol, 0, 0, 0, InpComment);
    }

    if(result) {
        PrintFormat(">>> ORDER EXECUTED! <<<");
        PrintFormat("Type: %s | Lots: %.2f | Price: %.5f | Ticket: %I64u",
                    (signal == 1 ? "BUY" : "SELL"), InpFixedLots, entryPrice,
                    g_trade.ResultOrder());
        g_dailyTrades++;
    } else {
        PrintFormat(">>> ORDER FAILED! <<<");
        PrintFormat("Error Code: %d", g_trade.ResultRetcode());
        PrintFormat("Description: %s", g_trade.ResultRetcodeDescription());
    }

    Print("========================================");
}

//+------------------------------------------------------------------+
//| 状態出力                                                         |
//+------------------------------------------------------------------+
void PrintStatus()
{
    MqlTick tick;
    SymbolInfoTick(_Symbol, tick);

    double spread = (tick.ask - tick.bid) / _Point / g_pointMultiplier;
    double atrPips = g_atr / _Point / g_pointMultiplier;
    double diff = g_emaFast - g_emaSlow;

    PrintFormat("[STATUS] Bars:%d | Ticks:%d | Signals:%d | Filtered:%d",
                g_totalBars, g_totalTicks, g_totalSignals, g_filteredSignals);
    PrintFormat("  EMA Fast=%.5f | Slow=%.5f | Diff=%.2fp",
                g_emaFast, g_emaSlow, diff / _Point / g_pointMultiplier);
    PrintFormat("  ATR=%.2fp | Spread=%.2fp", atrPips, spread);
}
//+------------------------------------------------------------------+
