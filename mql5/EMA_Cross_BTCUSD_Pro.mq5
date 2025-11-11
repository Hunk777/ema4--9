//+------------------------------------------------------------------+
//|                    EMA_Cross_BTCUSD_Pro.mq5                      |
//|          BTCUSD専用 プロフェッショナル秒足スキャルピング          |
//|                                              Copyright 2024      |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024"
#property link      ""
#property version   "3.00"
#property description "BTCUSD専用最適化 - 仮想通貨市場特化型"
#property description "高ボラティリティ対応 | 24時間稼働 | 動的リスク管理"

//+------------------------------------------------------------------+
//| インクルード                                                     |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>
CTrade g_trade;

//+------------------------------------------------------------------+
//| リングバッファクラス                                             |
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
    CRingBuffer(int capacity = 60) : m_capacity(capacity), m_head(0), m_size(0)
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

    // BTC特有：価格変動率
    double volatility;

    void Reset(datetime t, double price)
    {
        time = t;
        open = high = low = close = price;
        volume = tickCount = 0;
        buyVolume = sellVolume = 0;
        volatility = 0;
    }

    void Update(double price, long vol, bool isBuy)
    {
        if(price > high) high = price;
        if(price < low) low = price;
        close = price;
        volume += vol;
        tickCount++;
        if(isBuy) buyVolume += vol;
        else sellVolume += vol;

        // ボラティリティ計算（範囲/始値）
        if(open > 0) {
            volatility = (high - low) / open * 100.0;
        }
    }
};

//+------------------------------------------------------------------+
//| BTC統計クラス                                                    |
//+------------------------------------------------------------------+
class CBTCStatistics
{
private:
    double m_peakEquity;
    double m_maxDrawdown;
    double m_maxDrawdownUSD;

    // BTC特有統計
    double m_largestWin;
    double m_largestLoss;
    double m_avgHoldingTime;
    int m_totalHoldingSeconds;

public:
    int totalTrades;
    int winTrades;
    int loseTrades;
    double totalProfit;
    double grossProfit;
    double grossLoss;

    CBTCStatistics()
    {
        Reset();
    }

    void Reset()
    {
        totalTrades = winTrades = loseTrades = 0;
        totalProfit = grossProfit = grossLoss = 0;
        m_peakEquity = m_maxDrawdown = m_maxDrawdownUSD = 0;
        m_largestWin = m_largestLoss = 0;
        m_avgHoldingTime = 0;
        m_totalHoldingSeconds = 0;
    }

    void AddTrade(double profit, double equity, int holdingSeconds)
    {
        totalTrades++;
        if(profit > 0) {
            winTrades++;
            grossProfit += profit;
            if(profit > m_largestWin) m_largestWin = profit;
        } else if(profit < 0) {
            loseTrades++;
            grossLoss += MathAbs(profit);
            if(MathAbs(profit) > m_largestLoss) m_largestLoss = MathAbs(profit);
        }
        totalProfit += profit;

        m_totalHoldingSeconds += holdingSeconds;
        m_avgHoldingTime = m_totalHoldingSeconds / totalTrades;

        // ドローダウン計算
        if(equity > m_peakEquity) m_peakEquity = equity;
        if(m_peakEquity > 0) {
            double dd = (m_peakEquity - equity) / m_peakEquity * 100;
            double ddUSD = m_peakEquity - equity;
            if(dd > m_maxDrawdown) {
                m_maxDrawdown = dd;
                m_maxDrawdownUSD = ddUSD;
            }
        }
    }

    double GetWinRate() const { return totalTrades > 0 ? (double)winTrades / totalTrades * 100 : 0; }
    double GetProfitFactor() const { return grossLoss > 0 ? grossProfit / grossLoss : 0; }
    double GetExpectancy() const { return totalTrades > 0 ? totalProfit / totalTrades : 0; }
    double GetMaxDrawdown() const { return m_maxDrawdown; }
    double GetMaxDrawdownUSD() const { return m_maxDrawdownUSD; }
    double GetLargestWin() const { return m_largestWin; }
    double GetLargestLoss() const { return m_largestLoss; }
    double GetAvgHoldingTime() const { return m_avgHoldingTime; }
};

//+------------------------------------------------------------------+
//| BTCリスク管理クラス                                              |
//+------------------------------------------------------------------+
class CBTCRiskManager
{
private:
    double m_dailyStartBalance;
    int m_consecutiveLosses;
    int m_dailyTrades;
    double m_dailyProfit;

    // BTC特有：ボラティリティベースリスク
    double m_currentVolatility;
    bool m_highVolatilityMode;

public:
    CBTCRiskManager()
    {
        m_dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
        m_consecutiveLosses = 0;
        m_dailyTrades = 0;
        m_dailyProfit = 0;
        m_currentVolatility = 0;
        m_highVolatilityMode = false;
    }

    void OnNewDay()
    {
        m_dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
        m_dailyTrades = 0;
        m_dailyProfit = 0;
    }

    void OnTradeClose(double profit)
    {
        m_dailyTrades++;
        m_dailyProfit += profit;

        if(profit < 0) m_consecutiveLosses++;
        else m_consecutiveLosses = 0;
    }

    void UpdateVolatility(double volatility)
    {
        m_currentVolatility = volatility;
        // 3%以上の変動率で高ボラティリティモード
        m_highVolatilityMode = (volatility > 3.0);
    }

    bool CanTrade(double maxDailyLossPct, int maxDailyTrades, int maxConsecutiveLosses)
    {
        double balance = AccountInfoDouble(ACCOUNT_BALANCE);

        // 日次損失チェック
        if(m_dailyStartBalance > 0) {
            double dailyLossPct = (m_dailyStartBalance - balance) / m_dailyStartBalance * 100;
            if(dailyLossPct >= maxDailyLossPct) return false;
        }

        // 日次取引数チェック
        if(m_dailyTrades >= maxDailyTrades) return false;

        // 連敗チェック
        if(m_consecutiveLosses >= maxConsecutiveLosses) return false;

        // 高ボラティリティ時は取引数を制限
        if(m_highVolatilityMode && m_dailyTrades >= maxDailyTrades / 2) {
            return false;
        }

        return true;
    }

    double CalculateLotSize(double riskPct, double slPoints, double balance)
    {
        // BTC: ティック値ベースで計算
        double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
        double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
        double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

        // リスク金額
        double riskAmount = balance * riskPct / 100.0;

        // 高ボラティリティ時はリスクを半減
        if(m_highVolatilityMode) {
            riskAmount *= 0.5;
        }

        // ロット計算
        double lots = 0;
        if(slPoints > 0 && tickSize > 0) {
            lots = riskAmount / (slPoints / tickSize * tickValue);
        } else {
            lots = minLot;
        }

        // 丸め
        lots = MathFloor(lots / lotStep) * lotStep;
        lots = MathMax(minLot, MathMin(maxLot, lots));

        return lots;
    }

    int GetConsecutiveLosses() const { return m_consecutiveLosses; }
    int GetDailyTrades() const { return m_dailyTrades; }
    double GetDailyProfit() const { return m_dailyProfit; }
    bool IsHighVolatility() const { return m_highVolatilityMode; }
    double GetCurrentVolatility() const { return m_currentVolatility; }
};

//+------------------------------------------------------------------+
//| パラメータ - BTCUSD最適化                                        |
//+------------------------------------------------------------------+
input group "===== 秒足設定（BTC専用） ====="
input int      InpSecondsPerBar = 30;        // 秒足期間（BTCは30-60秒推奨）

input group "===== EMA設定（BTC最適化） ====="
input int      InpEMA_Fast = 5;              // 短期EMA（BTCは長めに）
input int      InpEMA_Slow = 13;             // 長期EMA
input int      InpEMA_Trend = 34;            // トレンドEMA（フィボナッチ数列）
input ENUM_APPLIED_PRICE InpAppliedPrice = PRICE_CLOSE;

input group "===== マルチタイムフレーム（BTC） ====="
input bool     InpUseMTF = true;             // MTF分析を使用
input ENUM_TIMEFRAMES InpMTF_Timeframe = PERIOD_M5; // 上位足（5分）
input int      InpMTF_EMA_Period = 89;       // 上位足EMA（フィボナッチ）

input group "===== シグナルフィルター（BTC専用） ====="
input double   InpMinCrossStrength = 10.0;   // 最小クロス強度（BTCは10-50 USD）
input bool     InpUseTrendFilter = true;     // トレンドフィルター
input bool     InpUseVolumeFilter = true;    // ボリュームフィルター（重要）
input double   InpMinVolumeDelta = 0.65;     // 最小ボリュームデルタ（65%）
input bool     InpUseSpreadFilter = true;    // スプレッドフィルター
input double   InpMaxSpreadUSD = 50.0;       // 最大スプレッド（USD）
input bool     InpUseATRFilter = true;       // ATRフィルター
input int      InpATR_Period = 30;           // ATR期間
input double   InpMinATR_USD = 50.0;         // 最小ATR（USD）
input double   InpMaxATR_USD = 2000.0;       // 最大ATR（USD）
input bool     InpUseVolatilityFilter = true;// ボラティリティフィルター
input double   InpMaxVolatility = 5.0;       // 最大ボラティリティ（%）

input group "===== 流動性時間帯（UTC） ====="
input bool     InpUseTimeFilter = true;      // 時間帯フィルター
input bool     InpTradeAsiaSession = false;  // アジア時間（00:00-09:00）
input bool     InpTradeEuropeSession = true; // 欧州時間（08:00-16:00）
input bool     InpTradeUSSession = true;     // 米国時間（13:00-22:00）
input bool     InpAvoidWeekend = true;       // 週末回避（流動性低）

input group "===== ポジション管理（BTC） ====="
input bool     InpUseDynamicLots = true;     // 動的ロットサイジング
input double   InpFixedLots = 0.01;          // 固定ロット（0.01 BTC）
input double   InpRiskPercent = 0.5;         // リスク（%）- BTCは低めに
input int      InpMinTradeIntervalSec = 60;  // 最小取引間隔（60秒）
input bool     InpCloseOpposite = true;      // 反対シグナルで決済

input group "===== リスク管理（BTC高ボラ対応） ====="
input bool     InpUseDynamicSL = true;       // 動的SL
input double   InpSL_ATR_Multi = 2.5;        // SL ATR倍率
input double   InpMinSL_USD = 100.0;         // 最小SL（USD）
input double   InpMaxSL_USD = 500.0;         // 最大SL（USD）
input bool     InpUseDynamicTP = true;       // 動的TP
input double   InpTP_ATR_Multi = 4.0;        // TP ATR倍率（リスクリワード1.6）
input double   InpMinTP_USD = 150.0;         // 最小TP（USD）
input double   InpMaxTP_USD = 800.0;         // 最大TP（USD）
input bool     InpUseTrailing = true;        // トレイリング
input double   InpTrailStart_USD = 200.0;    // トレイリング開始（USD）
input double   InpTrailStep_USD = 80.0;      // トレイリングステップ（USD）

input group "===== ドローダウン制御（BTC） ====="
input double   InpMaxDailyLoss = 2.0;        // 最大日次損失（%）
input int      InpMaxDailyTrades = 15;       // 最大日次取引数
input int      InpMaxConsecLosses = 4;       // 最大連敗数

input group "===== その他 ====="
input int      InpMagicNumber = 77777;       // マジックナンバー
input string   InpComment = "BTC_PRO";       // コメント
input int      InpSlippage = 100;            // スリッページ（BTCは大きめ）
input bool     InpShowPanel = true;          // パネル表示

//+------------------------------------------------------------------+
//| グローバル変数                                                   |
//+------------------------------------------------------------------+
CRingBuffer<SSecondBar> g_secondBars(60);
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
datetime g_positionOpenTime = 0;

CBTCStatistics g_stats;
CBTCRiskManager g_risk;

int g_totalTicks = 0;
int g_barsCreated = 0;
datetime g_startTime = 0;

int g_digits = 0;
double g_point = 0;

string g_prefix = "BTC_";

double g_lastBid = 0;
datetime g_lastDayCheck = 0;

// BTC特有
double g_currentPrice = 0;
double g_24hHigh = 0;
double g_24hLow = 0;

//+------------------------------------------------------------------+
//| 初期化                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
    PrintFormat("========================================");
    PrintFormat("EMA CROSS BTCUSD PRO v3.0 - 起動");
    PrintFormat("========================================");

    // シンボル検証
    if(StringFind(_Symbol, "BTC") < 0) {
        Print("警告: このEAはBTCUSD専用に最適化されています");
    }

    if(!ValidateParameters()) {
        return INIT_PARAMETERS_INCORRECT;
    }

    InitializeBrokerInfo();

    g_trade.SetExpertMagicNumber(InpMagicNumber);
    g_trade.SetDeviationInPoints(InpSlippage);
    g_trade.SetTypeFilling(ORDER_FILLING_IOC); // BTCはIOC推奨
    g_trade.SetAsyncMode(false);

    g_startTime = TimeCurrent();
    g_lastDayCheck = TimeCurrent();

    MqlTick tick;
    if(SymbolInfoTick(_Symbol, tick)) {
        g_currentBarTime = TimeCurrent();
        g_currentBarTime -= g_currentBarTime % InpSecondsPerBar;
        g_currentBar.Reset(g_currentBarTime, tick.bid);
        g_lastBid = tick.bid;
        g_currentPrice = tick.bid;
        g_24hHigh = tick.bid;
        g_24hLow = tick.bid;
    }

    InitializeEMAFromHistory();

    if(InpShowPanel) {
        CreatePanel();
    }

    PrintFormat("初期化完了");
    PrintFormat("シンボル: %s | 秒足: %ds | EMA: %d/%d/%d",
                _Symbol, InpSecondsPerBar, InpEMA_Fast, InpEMA_Slow, InpEMA_Trend);
    PrintFormat("価格: %.2f USD | 桁数: %d", g_currentPrice, g_digits);
    PrintFormat("最小ロット: %.8f BTC", SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));
    PrintFormat("========================================");

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| 終了処理                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    PrintFormat("========================================");
    PrintFormat("EMA CROSS BTCUSD PRO - 終了");
    PrintFormat("稼働時間: %d秒 | ティック: %d | バー: %d",
                (TimeCurrent() - g_startTime), g_totalTicks, g_barsCreated);
    PrintFormat("----------------------------------------");
    PrintFormat("【取引統計】");
    PrintFormat("総取引数: %d (勝ち: %d / 負け: %d)",
                g_stats.totalTrades, g_stats.winTrades, g_stats.loseTrades);
    PrintFormat("勝率: %.2f%% | PF: %.2f | 期待値: $%.2f",
                g_stats.GetWinRate(), g_stats.GetProfitFactor(), g_stats.GetExpectancy());
    PrintFormat("最大勝ち: $%.2f | 最大負け: $%.2f",
                g_stats.GetLargestWin(), g_stats.GetLargestLoss());
    PrintFormat("平均保有時間: %.0f秒", g_stats.GetAvgHoldingTime());
    PrintFormat("最大DD: %.2f%% ($%.2f)", g_stats.GetMaxDrawdown(), g_stats.GetMaxDrawdownUSD());
    PrintFormat("総損益: $%.2f", g_stats.totalProfit);
    PrintFormat("========================================");

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

    g_currentPrice = tick.bid;

    // 24時間高値安値更新
    if(tick.bid > g_24hHigh) g_24hHigh = tick.bid;
    if(tick.bid < g_24hLow) g_24hLow = tick.bid;

    // 日次チェック
    if(g_totalTicks % 500 == 0) {
        CheckNewDay();
    }

    datetime currentTime = TimeCurrent();
    datetime barTime = currentTime - (currentTime % InpSecondsPerBar);

    // 新しいバーの開始
    if(barTime > g_currentBarTime) {
        g_secondBars.Push(g_currentBar);

        g_currentBarTime = barTime;
        g_currentBar.Reset(barTime, tick.bid);
        g_barsCreated++;

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

    // UI更新
    if(g_totalTicks % 30 == 0 && InpShowPanel) {
        UpdatePanel();
    }
}

//+------------------------------------------------------------------+
//| パラメータ検証                                                   |
//+------------------------------------------------------------------+
bool ValidateParameters()
{
    if(InpSecondsPerBar < 10 || InpSecondsPerBar > 300) {
        Print("エラー: 秒足期間は10-300秒");
        return false;
    }

    if(InpEMA_Fast >= InpEMA_Slow || InpEMA_Slow >= InpEMA_Trend) {
        Print("エラー: EMA期間は Fast < Slow < Trend");
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
    g_point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

    PrintFormat("ブローカー情報: 桁数=%d, ポイント=%.5f", g_digits, g_point);
}

//+------------------------------------------------------------------+
//| EMA初期化                                                        |
//+------------------------------------------------------------------+
void InitializeEMAFromHistory()
{
    double close[];
    ArraySetAsSeries(close, true);

    int needed = MathMax(InpEMA_Trend, InpMTF_EMA_Period) * 2;
    int copied = CopyClose(_Symbol, PERIOD_M1, 0, needed, close);

    if(copied < InpEMA_Trend) {
        PrintFormat("警告: 履歴データ不足 (%d本)", copied);
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
    PrintFormat("EMA初期化: Fast=%.2f, Slow=%.2f, Trend=%.2f",
                g_emaFast, g_emaSlow, g_emaTrend);
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

    // MTF更新（200ティックに1回）
    if(InpUseMTF && g_totalTicks % 200 == 0) {
        UpdateMTF();
    }

    // ボラティリティ更新
    if(g_secondBars.Size() > 0) {
        g_risk.UpdateVolatility(bar.volatility);
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

    double crossStrength = MathAbs(diff_current);
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
        double spread = tick.ask - tick.bid;
        if(spread > InpMaxSpreadUSD) return false;
    }

    // ATRフィルター
    if(InpUseATRFilter && g_atr > 0) {
        if(g_atr < InpMinATR_USD || g_atr > InpMaxATR_USD) return false;
    }

    // ボラティリティフィルター
    if(InpUseVolatilityFilter) {
        SSecondBar bar;
        if(g_secondBars.Get(0, bar)) {
            if(bar.volatility > InpMaxVolatility) return false;
        }
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
        if(!IsGoodTradingTime()) return false;
    }

    return true;
}

//+------------------------------------------------------------------+
//| 取引時間帯チェック                                               |
//+------------------------------------------------------------------+
bool IsGoodTradingTime()
{
    MqlDateTime dt;
    TimeToStruct(TimeGMT(), dt); // UTC時刻

    // 週末回避
    if(InpAvoidWeekend && (dt.day_of_week == 0 || dt.day_of_week == 6)) {
        return false;
    }

    int hour = dt.hour;

    // アジア時間: 00:00-09:00
    if(InpTradeAsiaSession && hour >= 0 && hour < 9) return true;

    // 欧州時間: 08:00-16:00
    if(InpTradeEuropeSession && hour >= 8 && hour < 16) return true;

    // 米国時間: 13:00-22:00
    if(InpTradeUSSession && hour >= 13 && hour < 22) return true;

    return false;
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
        double slUSD = CalculateSL_USD();
        lots = g_risk.CalculateLotSize(InpRiskPercent, slUSD, AccountInfoDouble(ACCOUNT_BALANCE));
    } else {
        lots = InpFixedLots;
    }

    double sl = 0, tp = 0;
    double entryPrice = (signal == 1) ? tick.ask : tick.bid;

    if(InpUseDynamicSL) {
        double slUSD = CalculateSL_USD();
        sl = (signal == 1) ? entryPrice - slUSD : entryPrice + slUSD;
        sl = NormalizeDouble(sl, g_digits);
    }

    if(InpUseDynamicTP) {
        double tpUSD = CalculateTP_USD();
        tp = (signal == 1) ? entryPrice + tpUSD : entryPrice - tpUSD;
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
        g_positionOpenTime = TimeCurrent();

        PrintFormat("[OPEN] %s %.4f BTC @ $%.2f | SL:$%.2f | TP:$%.2f | Ticket:%I64u",
                    (signal == 1 ? "BUY" : "SELL"), lots, entryPrice, sl, tp, g_currentTicket);
    } else {
        PrintFormat("[ERROR] Order failed: %d - %s",
                    g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
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
    int holdingTime = (int)(TimeCurrent() - g_positionOpenTime);

    if(g_trade.PositionClose(g_currentTicket)) {
        PrintFormat("[CLOSE] Ticket:%I64u | P/L:$%.2f | Time:%ds",
                    g_currentTicket, profit, holdingTime);

        g_stats.AddTrade(profit, AccountInfoDouble(ACCOUNT_BALANCE), holdingTime);
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
                int holdingTime = (int)(TimeCurrent() - g_positionOpenTime);

                PrintFormat("[AUTO CLOSE] Ticket:%I64u | P/L:$%.2f | Time:%ds",
                            g_currentTicket, profit, holdingTime);

                g_stats.AddTrade(profit, AccountInfoDouble(ACCOUNT_BALANCE), holdingTime);
                g_risk.OnTradeClose(profit);

                g_currentTicket = 0;
                g_currentDirection = 0;
                break;
            }
        }
    }
}

//+------------------------------------------------------------------+
//| トレイリングストップ                                             |
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
        double profit = tick.bid - openPrice;

        if(profit >= InpTrailStart_USD) {
            newSL = tick.bid - InpTrailStep_USD;
            newSL = NormalizeDouble(newSL, g_digits);

            if(newSL > currentSL + g_point) {
                needUpdate = true;
            }
        }
    } else {
        double profit = openPrice - tick.ask;

        if(profit >= InpTrailStart_USD) {
            newSL = tick.ask + InpTrailStep_USD;
            newSL = NormalizeDouble(newSL, g_digits);

            if(currentSL == 0 || newSL < currentSL - g_point) {
                needUpdate = true;
            }
        }
    }

    if(needUpdate) {
        g_trade.PositionModify(g_currentTicket, newSL, currentTP);
    }
}

//+------------------------------------------------------------------+
//| SL計算（USD）                                                    |
//+------------------------------------------------------------------+
double CalculateSL_USD()
{
    double slUSD;

    if(g_atr > 0) {
        slUSD = g_atr * InpSL_ATR_Multi;
    } else {
        slUSD = (InpMinSL_USD + InpMaxSL_USD) / 2.0;
    }

    slUSD = MathMax(InpMinSL_USD, MathMin(InpMaxSL_USD, slUSD));

    return slUSD;
}

//+------------------------------------------------------------------+
//| TP計算（USD）                                                    |
//+------------------------------------------------------------------+
double CalculateTP_USD()
{
    double tpUSD;

    if(g_atr > 0) {
        tpUSD = g_atr * InpTP_ATR_Multi;
    } else {
        tpUSD = (InpMinTP_USD + InpMaxTP_USD) / 2.0;
    }

    tpUSD = MathMax(InpMinTP_USD, MathMin(InpMaxTP_USD, tpUSD));

    return tpUSD;
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

        // 24時間高値安値リセット
        g_24hHigh = g_currentPrice;
        g_24hLow = g_currentPrice;

        PrintFormat("=== 新しい日: %04d-%02d-%02d ===", dtNow.year, dtNow.mon, dtNow.day);
    }
}

//+------------------------------------------------------------------+
//| パネル作成                                                       |
//+------------------------------------------------------------------+
void CreatePanel()
{
    int width = 400;
    int height = 380;

    ObjectCreate(0, g_prefix + "BG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
    ObjectSetInteger(0, g_prefix + "BG", OBJPROP_CORNER, CORNER_LEFT_UPPER);
    ObjectSetInteger(0, g_prefix + "BG", OBJPROP_XDISTANCE, 10);
    ObjectSetInteger(0, g_prefix + "BG", OBJPROP_YDISTANCE, 25);
    ObjectSetInteger(0, g_prefix + "BG", OBJPROP_XSIZE, width);
    ObjectSetInteger(0, g_prefix + "BG", OBJPROP_YSIZE, height);
    ObjectSetInteger(0, g_prefix + "BG", OBJPROP_BGCOLOR, C'10,10,20');
    ObjectSetInteger(0, g_prefix + "BG", OBJPROP_BORDER_TYPE, BORDER_FLAT);
    ObjectSetInteger(0, g_prefix + "BG", OBJPROP_COLOR, clrOrange);
    ObjectSetInteger(0, g_prefix + "BG", OBJPROP_WIDTH, 2);
}

//+------------------------------------------------------------------+
//| パネル更新                                                       |
//+------------------------------------------------------------------+
void UpdatePanel()
{
    string lines[20];
    color colors[20];

    MqlTick tick;
    SymbolInfoTick(_Symbol, tick);

    double spread = tick.ask - tick.bid;
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);

    int idx = 0;

    lines[idx] = "═══ BTC PROFESSIONAL ═══";
    colors[idx++] = clrOrange;

    lines[idx] = StringFormat("BTCUSD | %ds | バー:%d", InpSecondsPerBar, g_secondBars.Size());
    colors[idx++] = clrWhite;

    lines[idx] = StringFormat("価格: $%.2f | Spr: $%.2f", g_currentPrice, spread);
    colors[idx++] = clrWhite;

    lines[idx] = "──────────────────";
    colors[idx++] = clrGray;

    lines[idx] = StringFormat("Fast EMA: $%.2f", g_emaFast);
    colors[idx++] = clrAqua;

    lines[idx] = StringFormat("Slow EMA: $%.2f", g_emaSlow);
    colors[idx++] = clrMagenta;

    lines[idx] = StringFormat("差分: $%.2f", g_emaFast - g_emaSlow);
    colors[idx++] = (g_emaFast > g_emaSlow) ? clrLime : clrRed;

    lines[idx] = StringFormat("Trend: $%.2f", g_emaTrend);
    colors[idx++] = clrYellow;

    lines[idx] = "──────────────────";
    colors[idx++] = clrGray;

    lines[idx] = StringFormat("ATR: $%.2f", g_atr);
    colors[idx++] = (g_atr >= InpMinATR_USD && g_atr <= InpMaxATR_USD) ? clrLime : clrOrange;

    SSecondBar bar;
    if(g_secondBars.Get(0, bar)) {
        lines[idx] = StringFormat("Vol: %.2f%% %s", bar.volatility,
                                  g_risk.IsHighVolatility() ? "[HIGH]" : "");
        colors[idx++] = g_risk.IsHighVolatility() ? clrRed : clrLime;
    } else {
        lines[idx] = "Vol: ---";
        colors[idx++] = clrGray;
    }

    lines[idx] = "──────────────────";
    colors[idx++] = clrGray;

    lines[idx] = StringFormat("ポジション: %s",
                              g_currentDirection == 1 ? "LONG" :
                              g_currentDirection == -1 ? "SHORT" : "---");
    colors[idx++] = g_currentDirection == 1 ? clrLime :
                    g_currentDirection == -1 ? clrRed : clrGray;

    if(g_currentTicket > 0 && PositionSelectByTicket(g_currentTicket)) {
        double profit = PositionGetDouble(POSITION_PROFIT);
        lines[idx] = StringFormat("P/L: $%.2f", profit);
        colors[idx++] = profit >= 0 ? clrLime : clrRed;
    } else {
        lines[idx] = "P/L: ---";
        colors[idx++] = clrGray;
    }

    lines[idx] = "──────────────────";
    colors[idx++] = clrGray;

    lines[idx] = StringFormat("取引: %dW-%dL (%.1f%%)",
                              g_stats.winTrades, g_stats.loseTrades, g_stats.GetWinRate());
    colors[idx++] = clrWhite;

    lines[idx] = StringFormat("PF: %.2f | 期待値: $%.2f",
                              g_stats.GetProfitFactor(), g_stats.GetExpectancy());
    colors[idx++] = clrCyan;

    lines[idx] = StringFormat("総損益: $%.2f", g_stats.totalProfit);
    colors[idx++] = g_stats.totalProfit >= 0 ? clrLime : clrRed;

    lines[idx] = StringFormat("MaxDD: %.2f%% ($%.2f)",
                              g_stats.GetMaxDrawdown(), g_stats.GetMaxDrawdownUSD());
    colors[idx++] = clrOrange;

    lines[idx] = "──────────────────";
    colors[idx++] = clrGray;

    lines[idx] = StringFormat("本日: %d取引 | 連敗: %d",
                              g_risk.GetDailyTrades(), g_risk.GetConsecutiveLosses());
    colors[idx++] = g_risk.GetConsecutiveLosses() >= 3 ? clrRed : clrGray;

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
