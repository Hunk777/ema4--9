//+------------------------------------------------------------------+
//|                   EMA_Cross_For_Scal_Pro_Light.mq5               |
//|              プロフェッショナル秒足スキャルピング - 軽量版        |
//|                                              Copyright 2024      |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024"
#property link      ""
#property version   "2.01"
#property description "軽量版 - メモリ・CPU最適化"
#property description "リアルティック秒足 | MTF分析 | 高度なリスク管理"

//+------------------------------------------------------------------+
//| インクルード                                                     |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>
CTrade g_trade;

//+------------------------------------------------------------------+
//| リングバッファクラス (O(1)効率)                                  |
//+------------------------------------------------------------------+
template<typename T>
class CRingBuffer
{
private:
    T m_buffer[];
    int m_capacity;
    int m_head;
    int m_size;

public:
    CRingBuffer(int capacity = 50) : m_capacity(capacity), m_head(0), m_size(0)
    {
        ArrayResize(m_buffer, m_capacity);
    }

    void Push(T &item)
    {
        m_buffer[m_head] = item;
        m_head = (m_head + 1) % m_capacity;
        if(m_size < m_capacity) m_size++;
    }

    bool Get(int index, T &out)
    {
        if(index >= m_size) return false;
        int pos = (m_head - 1 - index + m_capacity * 2) % m_capacity;
        out = m_buffer[pos];
        return true;
    }

    int Size() const { return m_size; }
};

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
    long tickCount;
    long buyVolume;
    long sellVolume;

    void Reset(datetime t, double price)
    {
        time = t;
        open = high = low = close = price;
        volume = tickCount = 0;
        buyVolume = sellVolume = 0;
    }

    void Update(double price, long vol, bool isBuy)
    {
        if(price > high) high = price;
        if(price < low) low = low;
        close = price;
        volume += vol;
        tickCount++;
        if(isBuy) buyVolume += vol;
        else sellVolume += vol;
    }
};

//+------------------------------------------------------------------+
//| 統計計算クラス（軽量版）                                         |
//+------------------------------------------------------------------+
class CStatistics
{
private:
    double m_peakEquity;
    double m_maxDrawdown;

public:
    int totalTrades;
    int winTrades;
    int loseTrades;
    double totalProfit;
    double grossProfit;
    double grossLoss;

    CStatistics() : m_peakEquity(0), m_maxDrawdown(0)
    {
        Reset();
    }

    void Reset()
    {
        totalTrades = winTrades = loseTrades = 0;
        totalProfit = grossProfit = grossLoss = 0;
        m_peakEquity = m_maxDrawdown = 0;
    }

    void AddTrade(double profit, double equity)
    {
        totalTrades++;
        if(profit > 0) {
            winTrades++;
            grossProfit += profit;
        } else if(profit < 0) {
            loseTrades++;
            grossLoss += MathAbs(profit);
        }
        totalProfit += profit;

        // ドローダウン計算
        if(equity > m_peakEquity) m_peakEquity = equity;
        if(m_peakEquity > 0) {
            double dd = (m_peakEquity - equity) / m_peakEquity * 100;
            if(dd > m_maxDrawdown) m_maxDrawdown = dd;
        }
    }

    double GetWinRate() const
    {
        return totalTrades > 0 ? (double)winTrades / totalTrades * 100 : 0;
    }

    double GetProfitFactor() const
    {
        return grossLoss > 0 ? grossProfit / grossLoss : 0;
    }

    double GetExpectancy() const
    {
        return totalTrades > 0 ? totalProfit / totalTrades : 0;
    }

    double GetMaxDrawdown() const { return m_maxDrawdown; }
};

//+------------------------------------------------------------------+
//| リスク管理クラス                                                 |
//+------------------------------------------------------------------+
class CRiskManager
{
private:
    double m_dailyStartBalance;
    int m_consecutiveLosses;
    int m_dailyTrades;

public:
    CRiskManager()
    {
        m_dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
        m_consecutiveLosses = 0;
        m_dailyTrades = 0;
    }

    void OnNewDay()
    {
        m_dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
        m_dailyTrades = 0;
    }

    void OnTradeClose(double profit)
    {
        m_dailyTrades++;
        if(profit < 0) m_consecutiveLosses++;
        else m_consecutiveLosses = 0;
    }

    bool CanTrade(double maxDailyLossPct, int maxDailyTrades, int maxConsecutiveLosses)
    {
        // 日次損失チェック
        double balance = AccountInfoDouble(ACCOUNT_BALANCE);
        if(m_dailyStartBalance > 0) {
            double dailyLossPct = (m_dailyStartBalance - balance) / m_dailyStartBalance * 100;
            if(dailyLossPct >= maxDailyLossPct) return false;
        }

        // 日次取引数チェック
        if(m_dailyTrades >= maxDailyTrades) return false;

        // 連敗チェック
        if(m_consecutiveLosses >= maxConsecutiveLosses) return false;

        return true;
    }

    double CalculateLotSize(double riskPct, double slPips, double balance)
    {
        double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
        double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
        double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

        double riskAmount = balance * riskPct / 100.0;
        double slValue = slPips * _Point * 10;
        double lots = riskAmount / (slValue / tickSize * tickValue);

        lots = MathFloor(lots / lotStep) * lotStep;
        lots = MathMax(minLot, MathMin(maxLot, lots));

        return lots;
    }

    int GetConsecutiveLosses() const { return m_consecutiveLosses; }
    int GetDailyTrades() const { return m_dailyTrades; }
};

//+------------------------------------------------------------------+
//| パラメータ                                                       |
//+------------------------------------------------------------------+
input group "===== 秒足設定 ====="
input int      InpSecondsPerBar = 10;        // 秒足期間

input group "===== EMA設定 ====="
input int      InpEMA_Fast = 3;              // 短期EMA
input int      InpEMA_Slow = 8;              // 長期EMA
input int      InpEMA_Trend = 21;            // トレンドEMA
input ENUM_APPLIED_PRICE InpAppliedPrice = PRICE_CLOSE;

input group "===== マルチタイムフレーム ====="
input bool     InpUseMTF = true;             // MTF分析を使用
input ENUM_TIMEFRAMES InpMTF_Timeframe = PERIOD_M1;
input int      InpMTF_EMA_Period = 50;

input group "===== シグナルフィルター ====="
input double   InpMinCrossStrength = 0.5;    // 最小クロス強度(pips)
input bool     InpUseTrendFilter = true;     // トレンドフィルター
input bool     InpUseVolumeFilter = true;    // ボリュームフィルター
input double   InpMinVolumeDelta = 0.6;      // 最小ボリュームデルタ比率
input bool     InpUseSpreadFilter = true;    // スプレッドフィルター
input double   InpMaxSpreadPips = 1.0;       // 最大スプレッド(pips)
input bool     InpUseATRFilter = true;       // ATRフィルター
input int      InpATR_Period = 20;           // ATR期間(秒足)
input double   InpMinATR_Pips = 1.0;         // 最小ATR(pips)
input double   InpMaxATR_Pips = 50.0;        // 最大ATR(pips)

input group "===== 時間帯フィルター ====="
input bool     InpUseTimeFilter = true;      // 時間帯フィルター
input int      InpStartHour = 8;             // 取引開始時刻
input int      InpEndHour = 21;              // 取引終了時刻

input group "===== ポジション管理 ====="
input bool     InpUseDynamicLots = true;     // 動的ロットサイジング
input double   InpFixedLots = 0.01;          // 固定ロット
input double   InpRiskPercent = 1.0;         // リスク(%)
input int      InpMinTradeIntervalSec = 15;  // 最小取引間隔(秒)
input bool     InpCloseOpposite = true;      // 反対シグナルで決済

input group "===== リスク管理 ====="
input bool     InpUseDynamicSL = true;       // 動的SL
input double   InpSL_ATR_Multi = 2.0;        // SL ATR倍率
input double   InpMinSL_Pips = 3.0;          // 最小SL(pips)
input double   InpMaxSL_Pips = 15.0;         // 最大SL(pips)
input bool     InpUseDynamicTP = true;       // 動的TP
input double   InpTP_ATR_Multi = 3.0;        // TP ATR倍率
input double   InpMinTP_Pips = 5.0;          // 最小TP(pips)
input double   InpMaxTP_Pips = 30.0;         // 最大TP(pips)
input bool     InpUseTrailing = true;        // トレイリング
input double   InpTrailStart_Pips = 8.0;     // トレイリング開始(pips)
input double   InpTrailStep_Pips = 3.0;      // トレイリングステップ(pips)

input group "===== ドローダウン制御 ====="
input double   InpMaxDailyLoss = 3.0;        // 最大日次損失(%)
input int      InpMaxDailyTrades = 20;       // 最大日次取引数
input int      InpMaxConsecLosses = 5;       // 最大連敗数

input group "===== その他 ====="
input int      InpMagicNumber = 88888;       // マジックナンバー
input string   InpComment = "SCAL_LIGHT";    // コメント
input int      InpSlippage = 5;              // スリッページ
input bool     InpShowPanel = true;          // パネル表示

//+------------------------------------------------------------------+
//| グローバル変数                                                   |
//+------------------------------------------------------------------+
CRingBuffer<SSecondBar> g_secondBars(50);    // 50本に削減
SSecondBar g_currentBar;
datetime g_currentBarTime = 0;

double g_emaFast = 0, g_emaSlow = 0, g_emaTrend = 0;
double g_emaFast_prev = 0, g_emaSlow_prev = 0;
double g_mtf_ema = 0;
bool g_emaInitialized = false;

double g_atr = 0;

ulong g_currentTicket = 0;
int g_currentDirection = 0;
datetime g_lastTradeTime = 0;

CStatistics g_stats;
CRiskManager g_risk;

int g_totalTicks = 0;
datetime g_startTime = 0;

double g_pointMultiplier = 1.0;
int g_digits = 0;

string g_prefix = "SPLT_";

double g_lastBid = 0;
datetime g_lastDayCheck = 0;

//+------------------------------------------------------------------+
//| 初期化                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
    Print("EMA CROSS SCAL PRO LIGHT v2.01 - Starting...");

    if(!ValidateParameters()) {
        return INIT_PARAMETERS_INCORRECT;
    }

    InitializeBrokerInfo();

    g_trade.SetExpertMagicNumber(InpMagicNumber);
    g_trade.SetDeviationInPoints(InpSlippage);
    g_trade.SetTypeFilling(ORDER_FILLING_FOK);
    g_trade.SetAsyncMode(false);

    g_startTime = TimeCurrent();
    g_lastDayCheck = TimeCurrent();

    MqlTick tick;
    if(SymbolInfoTick(_Symbol, tick)) {
        g_currentBarTime = TimeCurrent();
        g_currentBarTime -= g_currentBarTime % InpSecondsPerBar;
        g_currentBar.Reset(g_currentBarTime, tick.bid);
        g_lastBid = tick.bid;
    }

    InitializeEMAFromHistory();

    if(InpShowPanel) {
        CreatePanel();
    }

    PrintFormat("Initialized: %s | %ds | EMA %d/%d/%d",
                _Symbol, InpSecondsPerBar, InpEMA_Fast, InpEMA_Slow, InpEMA_Trend);

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| 終了処理                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    PrintFormat("=== SCAL PRO LIGHT - Stopped ===");
    PrintFormat("Runtime: %ds | Ticks: %d", (TimeCurrent() - g_startTime), g_totalTicks);
    PrintFormat("Trades: %d (W:%d/L:%d) | WinRate: %.1f%% | PF: %.2f",
                g_stats.totalTrades, g_stats.winTrades, g_stats.loseTrades,
                g_stats.GetWinRate(), g_stats.GetProfitFactor());
    PrintFormat("Total P/L: %.2f | MaxDD: %.2f%%", g_stats.totalProfit, g_stats.GetMaxDrawdown());

    ObjectsDeleteAll(0, g_prefix);
}

//+------------------------------------------------------------------+
//| ティック処理                                                     |
//+------------------------------------------------------------------+
void OnTick()
{
    g_totalTicks++;

    MqlTick tick;
    if(!SymbolInfoTick(_Symbol, tick)) return;

    // 日次チェック（1000ティックに1回）
    if(g_totalTicks % 1000 == 0) {
        CheckNewDay();
    }

    datetime currentTime = TimeCurrent();
    datetime barTime = currentTime - (currentTime % InpSecondsPerBar);

    // 新しいバーの開始
    if(barTime > g_currentBarTime) {
        g_secondBars.Push(g_currentBar);

        g_currentBarTime = barTime;
        g_currentBar.Reset(barTime, tick.bid);

        CalculateEMA();

        if(g_emaInitialized) {
            int signal = DetectSignal();
            if(signal != 0) {
                ProcessSignal(signal);
            }
        }
    } else {
        bool isBuy = (tick.bid >= g_lastBid);
        g_currentBar.Update(tick.bid, tick.volume, isBuy);
    }

    g_lastBid = tick.bid;

    // トレイリング
    if(InpUseTrailing && g_currentTicket > 0) {
        UpdateTrailingStop();
    }

    // UI更新（50ティックに1回）
    if(g_totalTicks % 50 == 0 && InpShowPanel) {
        UpdatePanel();
    }
}

//+------------------------------------------------------------------+
//| パラメータ検証                                                   |
//+------------------------------------------------------------------+
bool ValidateParameters()
{
    if(InpSecondsPerBar < 1 || InpSecondsPerBar > 60) {
        Print("Error: Seconds per bar must be 1-60");
        return false;
    }

    if(InpEMA_Fast >= InpEMA_Slow || InpEMA_Slow >= InpEMA_Trend) {
        Print("Error: EMA periods must be Fast < Slow < Trend");
        return false;
    }

    return true;
}

//+------------------------------------------------------------------+
//| ブローカー情報初期化                                             |
//+------------------------------------------------------------------+
void InitializeBrokerInfo()
{
    g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    g_pointMultiplier = (g_digits == 5 || g_digits == 3) ? 10.0 : 1.0;
}

//+------------------------------------------------------------------+
//| 1分足からEMA初期化                                               |
//+------------------------------------------------------------------+
void InitializeEMAFromHistory()
{
    double close[];
    ArraySetAsSeries(close, true);

    int needed = MathMax(InpEMA_Trend, InpMTF_EMA_Period) * 2;
    int copied = CopyClose(_Symbol, PERIOD_M1, 0, needed, close);

    if(copied < InpEMA_Trend) {
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

    // MTF EMA
    if(InpUseMTF) {
        double mtfClose[];
        ArraySetAsSeries(mtfClose, true);
        if(CopyClose(_Symbol, InpMTF_Timeframe, 0, InpMTF_EMA_Period, mtfClose) > 0) {
            double sum = 0;
            for(int i = 0; i < InpMTF_EMA_Period; i++) sum += mtfClose[i];
            g_mtf_ema = sum / InpMTF_EMA_Period;
        }
    }

    g_emaInitialized = true;
}

//+------------------------------------------------------------------+
//| EMA計算                                                          |
//+------------------------------------------------------------------+
void CalculateEMA()
{
    SSecondBar bar;
    if(!g_secondBars.Get(0, bar)) return;

    double price = bar.close;

    g_emaFast_prev = g_emaFast;
    g_emaSlow_prev = g_emaSlow;

    double alphaFast = 2.0 / (InpEMA_Fast + 1.0);
    double alphaSlow = 2.0 / (InpEMA_Slow + 1.0);
    double alphaTrend = 2.0 / (InpEMA_Trend + 1.0);

    g_emaFast = price * alphaFast + g_emaFast * (1.0 - alphaFast);
    g_emaSlow = price * alphaSlow + g_emaSlow * (1.0 - alphaSlow);
    g_emaTrend = price * alphaTrend + g_emaTrend * (1.0 - alphaTrend);

    CalculateATR();

    // MTF更新（300ティックに1回）
    if(InpUseMTF && g_totalTicks % 300 == 0) {
        UpdateMTF();
    }
}

//+------------------------------------------------------------------+
//| ATR計算                                                          |
//+------------------------------------------------------------------+
void CalculateATR()
{
    if(g_secondBars.Size() < InpATR_Period + 1) return;

    double sum = 0;
    SSecondBar bar1, bar2;

    for(int i = 0; i < InpATR_Period; i++) {
        if(!g_secondBars.Get(i, bar1)) continue;
        if(!g_secondBars.Get(i + 1, bar2)) continue;

        double tr = MathMax(bar1.high - bar1.low,
                    MathMax(MathAbs(bar1.high - bar2.close),
                            MathAbs(bar1.low - bar2.close)));
        sum += tr;
    }

    g_atr = sum / InpATR_Period;
}

//+------------------------------------------------------------------+
//| MTF更新                                                          |
//+------------------------------------------------------------------+
void UpdateMTF()
{
    double close[];
    ArraySetAsSeries(close, true);

    if(CopyClose(_Symbol, InpMTF_Timeframe, 0, 2, close) > 0) {
        double alpha = 2.0 / (InpMTF_EMA_Period + 1.0);
        g_mtf_ema = close[0] * alpha + g_mtf_ema * (1.0 - alpha);
    }
}

//+------------------------------------------------------------------+
//| シグナル検出                                                     |
//+------------------------------------------------------------------+
int DetectSignal()
{
    if(g_secondBars.Size() < 2) return 0;

    double diff_current = g_emaFast - g_emaSlow;
    double diff_prev = g_emaFast_prev - g_emaSlow_prev;

    double crossStrength = MathAbs(diff_current) / _Point / g_pointMultiplier;
    if(crossStrength < InpMinCrossStrength) return 0;

    int signal = 0;

    if(diff_prev <= 0 && diff_current > 0) {
        signal = 1;
    }
    else if(diff_prev >= 0 && diff_current < 0) {
        signal = -1;
    }

    if(signal == 0) return 0;

    return PassFilters(signal) ? signal : 0;
}

//+------------------------------------------------------------------+
//| フィルターチェック                                               |
//+------------------------------------------------------------------+
bool PassFilters(int signal)
{
    MqlTick tick;
    if(!SymbolInfoTick(_Symbol, tick)) return false;

    // スプレッドフィルター
    if(InpUseSpreadFilter) {
        double spread = (tick.ask - tick.bid) / _Point / g_pointMultiplier;
        if(spread > InpMaxSpreadPips) return false;
    }

    // ATRフィルター
    if(InpUseATRFilter && g_atr > 0) {
        double atrPips = g_atr / _Point / g_pointMultiplier;
        if(atrPips < InpMinATR_Pips || atrPips > InpMaxATR_Pips) return false;
    }

    // トレンドフィルター
    if(InpUseTrendFilter) {
        if(signal == 1 && g_emaFast < g_emaTrend) return false;
        if(signal == -1 && g_emaFast > g_emaTrend) return false;
    }

    // MTFフィルター
    if(InpUseMTF && g_mtf_ema > 0) {
        if(signal == 1 && tick.bid < g_mtf_ema) return false;
        if(signal == -1 && tick.bid > g_mtf_ema) return false;
    }

    // ボリュームフィルター
    if(InpUseVolumeFilter) {
        SSecondBar bar;
        if(g_secondBars.Get(0, bar)) {
            double totalVol = (double)(bar.buyVolume + bar.sellVolume);
            if(totalVol > 0) {
                double buyRatio = (double)bar.buyVolume / totalVol;
                double sellRatio = (double)bar.sellVolume / totalVol;

                if(signal == 1 && buyRatio < InpMinVolumeDelta) return false;
                if(signal == -1 && sellRatio < InpMinVolumeDelta) return false;
            }
        }
    }

    // 時間帯フィルター
    if(InpUseTimeFilter) {
        MqlDateTime dt;
        TimeToStruct(TimeCurrent(), dt);
        if(dt.hour < InpStartHour || dt.hour >= InpEndHour) return false;
    }

    return true;
}

//+------------------------------------------------------------------+
//| シグナル処理                                                     |
//+------------------------------------------------------------------+
void ProcessSignal(int signal)
{
    if(!g_risk.CanTrade(InpMaxDailyLoss, InpMaxDailyTrades, InpMaxConsecLosses)) {
        return;
    }

    if(g_lastTradeTime > 0) {
        int elapsed = (int)(TimeCurrent() - g_lastTradeTime);
        if(elapsed < InpMinTradeIntervalSec) return;
    }

    if(InpCloseOpposite && g_currentDirection != 0 && g_currentDirection != signal) {
        ClosePosition();
    }

    if(g_currentDirection == signal) return;

    OpenPosition(signal);
}

//+------------------------------------------------------------------+
//| ポジションオープン                                               |
//+------------------------------------------------------------------+
void OpenPosition(int signal)
{
    MqlTick tick;
    if(!SymbolInfoTick(_Symbol, tick)) return;

    double lots;
    if(InpUseDynamicLots) {
        double slPips = CalculateSL_Pips();
        lots = g_risk.CalculateLotSize(InpRiskPercent, slPips,
                                        AccountInfoDouble(ACCOUNT_BALANCE));
    } else {
        lots = InpFixedLots;
    }

    double sl = 0, tp = 0;
    double entryPrice = (signal == 1) ? tick.ask : tick.bid;

    if(InpUseDynamicSL) {
        double slPips = CalculateSL_Pips();
        double slDist = slPips * _Point * g_pointMultiplier;
        sl = (signal == 1) ? entryPrice - slDist : entryPrice + slDist;
        sl = NormalizeDouble(sl, g_digits);
    }

    if(InpUseDynamicTP) {
        double tpPips = CalculateTP_Pips();
        double tpDist = tpPips * _Point * g_pointMultiplier;
        tp = (signal == 1) ? entryPrice + tpDist : entryPrice - tpDist;
        tp = NormalizeDouble(tp, g_digits);
    }

    bool result;
    if(signal == 1) {
        result = g_trade.Buy(lots, _Symbol, 0, sl, tp, InpComment);
    } else {
        result = g_trade.Sell(lots, _Symbol, 0, sl, tp, InpComment);
    }

    if(result) {
        g_currentTicket = g_trade.ResultOrder();
        g_currentDirection = signal;
        g_lastTradeTime = TimeCurrent();

        PrintFormat("[OPEN] %s %.2f @ %.5f SL:%.5f TP:%.5f",
                    (signal == 1 ? "BUY" : "SELL"), lots, entryPrice, sl, tp);
    }
}

//+------------------------------------------------------------------+
//| ポジションクローズ                                               |
//+------------------------------------------------------------------+
void ClosePosition()
{
    if(g_currentTicket == 0) return;

    if(!PositionSelectByTicket(g_currentTicket)) {
        CheckClosedPosition();
        return;
    }

    double profit = PositionGetDouble(POSITION_PROFIT);

    if(g_trade.PositionClose(g_currentTicket)) {
        PrintFormat("[CLOSE] Ticket:%I64u | P/L:%.2f", g_currentTicket, profit);

        g_stats.AddTrade(profit, AccountInfoDouble(ACCOUNT_BALANCE));
        g_risk.OnTradeClose(profit);

        g_currentTicket = 0;
        g_currentDirection = 0;
    }
}

//+------------------------------------------------------------------+
//| 決済済みポジションチェック                                       |
//+------------------------------------------------------------------+
void CheckClosedPosition()
{
    if(g_currentTicket == 0) return;

    if(HistorySelectByPosition(g_currentTicket)) {
        int deals = HistoryDealsTotal();

        for(int i = deals - 1; i >= 0; i--) {
            ulong dealTicket = HistoryDealGetTicket(i);
            if(dealTicket == 0) continue;

            if(HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID) == g_currentTicket) {
                double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);

                PrintFormat("[AUTO CLOSE] Ticket:%I64u | P/L:%.2f", g_currentTicket, profit);

                g_stats.AddTrade(profit, AccountInfoDouble(ACCOUNT_BALANCE));
                g_risk.OnTradeClose(profit);

                g_currentTicket = 0;
                g_currentDirection = 0;
                break;
            }
        }
    }
}

//+------------------------------------------------------------------+
//| トレイリングストップ更新                                         |
//+------------------------------------------------------------------+
void UpdateTrailingStop()
{
    if(!PositionSelectByTicket(g_currentTicket)) {
        CheckClosedPosition();
        return;
    }

    double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
    double currentSL = PositionGetDouble(POSITION_SL);
    double currentTP = PositionGetDouble(POSITION_TP);

    MqlTick tick;
    if(!SymbolInfoTick(_Symbol, tick)) return;

    ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

    double newSL = 0;
    bool needUpdate = false;

    if(type == POSITION_TYPE_BUY) {
        double profit = (tick.bid - openPrice) / _Point / g_pointMultiplier;

        if(profit >= InpTrailStart_Pips) {
            newSL = tick.bid - InpTrailStep_Pips * _Point * g_pointMultiplier;
            newSL = NormalizeDouble(newSL, g_digits);

            if(newSL > currentSL + _Point * g_pointMultiplier) {
                needUpdate = true;
            }
        }
    } else {
        double profit = (openPrice - tick.ask) / _Point / g_pointMultiplier;

        if(profit >= InpTrailStart_Pips) {
            newSL = tick.ask + InpTrailStep_Pips * _Point * g_pointMultiplier;
            newSL = NormalizeDouble(newSL, g_digits);

            if(currentSL == 0 || newSL < currentSL - _Point * g_pointMultiplier) {
                needUpdate = true;
            }
        }
    }

    if(needUpdate) {
        g_trade.PositionModify(g_currentTicket, newSL, currentTP);
    }
}

//+------------------------------------------------------------------+
//| SL計算（pips）                                                   |
//+------------------------------------------------------------------+
double CalculateSL_Pips()
{
    double slPips;

    if(g_atr > 0) {
        slPips = g_atr / _Point / g_pointMultiplier * InpSL_ATR_Multi;
    } else {
        slPips = (InpMinSL_Pips + InpMaxSL_Pips) / 2.0;
    }

    slPips = MathMax(InpMinSL_Pips, MathMin(InpMaxSL_Pips, slPips));

    return slPips;
}

//+------------------------------------------------------------------+
//| TP計算（pips）                                                   |
//+------------------------------------------------------------------+
double CalculateTP_Pips()
{
    double tpPips;

    if(g_atr > 0) {
        tpPips = g_atr / _Point / g_pointMultiplier * InpTP_ATR_Multi;
    } else {
        tpPips = (InpMinTP_Pips + InpMaxTP_Pips) / 2.0;
    }

    tpPips = MathMax(InpMinTP_Pips, MathMin(InpMaxTP_Pips, tpPips));

    return tpPips;
}

//+------------------------------------------------------------------+
//| 新しい日チェック                                                 |
//+------------------------------------------------------------------+
void CheckNewDay()
{
    MqlDateTime dtNow, dtLast;
    TimeToStruct(TimeCurrent(), dtNow);
    TimeToStruct(g_lastDayCheck, dtLast);

    if(dtNow.day != dtLast.day) {
        g_risk.OnNewDay();
        g_lastDayCheck = TimeCurrent();
        PrintFormat("=== New Day: %04d-%02d-%02d ===", dtNow.year, dtNow.mon, dtNow.day);
    }
}

//+------------------------------------------------------------------+
//| パネル作成                                                       |
//+------------------------------------------------------------------+
void CreatePanel()
{
    int width = 320;
    int height = 320;

    ObjectCreate(0, g_prefix + "BG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
    ObjectSetInteger(0, g_prefix + "BG", OBJPROP_CORNER, CORNER_LEFT_UPPER);
    ObjectSetInteger(0, g_prefix + "BG", OBJPROP_XDISTANCE, 10);
    ObjectSetInteger(0, g_prefix + "BG", OBJPROP_YDISTANCE, 25);
    ObjectSetInteger(0, g_prefix + "BG", OBJPROP_XSIZE, width);
    ObjectSetInteger(0, g_prefix + "BG", OBJPROP_YSIZE, height);
    ObjectSetInteger(0, g_prefix + "BG", OBJPROP_BGCOLOR, C'15,15,25');
    ObjectSetInteger(0, g_prefix + "BG", OBJPROP_BORDER_TYPE, BORDER_FLAT);
    ObjectSetInteger(0, g_prefix + "BG", OBJPROP_COLOR, clrDodgerBlue);
    ObjectSetInteger(0, g_prefix + "BG", OBJPROP_WIDTH, 2);
}

//+------------------------------------------------------------------+
//| パネル更新（軽量版）                                             |
//+------------------------------------------------------------------+
void UpdatePanel()
{
    string lines[16];
    color colors[16];

    MqlTick tick;
    SymbolInfoTick(_Symbol, tick);

    double spread = (tick.ask - tick.bid) / _Point / g_pointMultiplier;
    double atrPips = g_atr / _Point / g_pointMultiplier;

    int idx = 0;

    lines[idx] = "═══ SCAL PRO LIGHT ═══";
    colors[idx++] = clrGold;

    lines[idx] = StringFormat("%s | %ds", _Symbol, InpSecondsPerBar);
    colors[idx++] = clrWhite;

    lines[idx] = "─────────────────";
    colors[idx++] = clrGray;

    lines[idx] = StringFormat("Fast: %.5f", g_emaFast);
    colors[idx++] = clrAqua;

    lines[idx] = StringFormat("Slow: %.5f", g_emaSlow);
    colors[idx++] = clrMagenta;

    lines[idx] = StringFormat("Diff: %.2fp", (g_emaFast - g_emaSlow) / _Point / g_pointMultiplier);
    colors[idx++] = (g_emaFast > g_emaSlow) ? clrLime : clrRed;

    lines[idx] = "─────────────────";
    colors[idx++] = clrGray;

    lines[idx] = StringFormat("ATR: %.1fp | Spr: %.1fp", atrPips, spread);
    colors[idx++] = clrWhite;

    lines[idx] = StringFormat("Pos: %s", g_currentDirection == 1 ? "BUY" :
                              g_currentDirection == -1 ? "SELL" : "---");
    colors[idx++] = g_currentDirection == 1 ? clrLime :
                    g_currentDirection == -1 ? clrRed : clrGray;

    if(g_currentTicket > 0 && PositionSelectByTicket(g_currentTicket)) {
        double profit = PositionGetDouble(POSITION_PROFIT);
        lines[idx] = StringFormat("P/L: %.2f", profit);
        colors[idx++] = profit >= 0 ? clrLime : clrRed;
    } else {
        lines[idx] = "P/L: ---";
        colors[idx++] = clrGray;
    }

    lines[idx] = "─────────────────";
    colors[idx++] = clrGray;

    lines[idx] = StringFormat("Trades: %dW-%dL", g_stats.winTrades, g_stats.loseTrades);
    colors[idx++] = clrWhite;

    lines[idx] = StringFormat("WR: %.1f%% | PF: %.2f",
                              g_stats.GetWinRate(), g_stats.GetProfitFactor());
    colors[idx++] = clrCyan;

    lines[idx] = StringFormat("Total: %.2f", g_stats.totalProfit);
    colors[idx++] = g_stats.totalProfit >= 0 ? clrLime : clrRed;

    lines[idx] = "─────────────────";
    colors[idx++] = clrGray;

    lines[idx] = StringFormat("Daily: %d | Loss: %d",
                              g_risk.GetDailyTrades(), g_risk.GetConsecutiveLosses());
    colors[idx++] = g_risk.GetConsecutiveLosses() >= 3 ? clrOrange : clrGray;

    // 描画
    for(int i = 0; i < ArraySize(lines); i++) {
        string objName = g_prefix + "L" + IntegerToString(i);

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
