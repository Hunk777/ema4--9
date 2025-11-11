//+------------------------------------------------------------------+
//|                      EMA_Cross_For_Scal_Pro.mq5                  |
//|                プロフェッショナル秒足スキャルピングシステム        |
//|                                              Copyright 2024      |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024"
#property link      ""
#property version   "2.00"
#property description "90点レベル - プロダクショングレードスキャルピングEA"
#property description "リアルティック秒足 | MTF分析 | 高度なリスク管理 | 統計エンジン"

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
    CRingBuffer(int capacity = 100) : m_capacity(capacity), m_head(0), m_size(0)
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

    void Clear()
    {
        m_size = 0;
        m_head = 0;
    }
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
    long tickCount;      // ティック数
    long buyVolume;      // 買いボリューム (long型に修正)
    long sellVolume;     // 売りボリューム (long型に修正)

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
        if(price < low) low = price;
        close = price;
        volume += vol;
        tickCount++;
        if(isBuy) buyVolume += vol;    // 修正: long + long
        else sellVolume += vol;         // 修正: long + long
    }
};

//+------------------------------------------------------------------+
//| 統計計算クラス                                                   |
//+------------------------------------------------------------------+
class CStatistics
{
private:
    double m_returns[];
    double m_equity[];
    int m_maxReturnSize;
    double m_peakEquity;
    double m_maxDrawdown;

public:
    int totalTrades;
    int winTrades;
    int loseTrades;
    double totalProfit;
    double totalLoss;
    double grossProfit;
    double grossLoss;

    CStatistics() : m_maxReturnSize(1000), m_peakEquity(0), m_maxDrawdown(0)
    {
        ArrayResize(m_returns, m_maxReturnSize);
        ArrayResize(m_equity, m_maxReturnSize);
        Reset();
    }

    void Reset()
    {
        totalTrades = winTrades = loseTrades = 0;
        totalProfit = totalLoss = grossProfit = grossLoss = 0;
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

        // リターン記録
        if(totalTrades < m_maxReturnSize) {
            m_returns[totalTrades - 1] = profit;
            m_equity[totalTrades - 1] = equity;
        }

        // ドローダウン計算
        if(equity > m_peakEquity) m_peakEquity = equity;
        double dd = (m_peakEquity - equity) / m_peakEquity * 100;
        if(dd > m_maxDrawdown) m_maxDrawdown = dd;
    }

    double GetWinRate() const
    {
        return totalTrades > 0 ? (double)winTrades / totalTrades * 100 : 0;
    }

    double GetProfitFactor() const
    {
        return grossLoss > 0 ? grossProfit / grossLoss : 0;
    }

    double GetAverageWin() const
    {
        return winTrades > 0 ? grossProfit / winTrades : 0;
    }

    double GetAverageLoss() const
    {
        return loseTrades > 0 ? grossLoss / loseTrades : 0;
    }

    double GetExpectancy() const
    {
        return totalTrades > 0 ? totalProfit / totalTrades : 0;
    }

    double GetSharpeRatio() const
    {
        if(totalTrades < 2) return 0;

        double mean = totalProfit / totalTrades;
        double variance = 0;

        for(int i = 0; i < totalTrades && i < m_maxReturnSize; i++) {
            variance += MathPow(m_returns[i] - mean, 2);
        }

        double stdDev = MathSqrt(variance / totalTrades);
        return stdDev > 0 ? mean / stdDev * MathSqrt(252) : 0; // 年率化
    }

    double GetMaxDrawdown() const { return m_maxDrawdown; }
};

//+------------------------------------------------------------------+
//| リスク管理クラス                                                 |
//+------------------------------------------------------------------+
class CRiskManager
{
private:
    double m_initialBalance;
    double m_dailyStartBalance;
    datetime m_dailyStartTime;
    int m_consecutiveLosses;
    int m_dailyTrades;
    double m_dailyProfit;

public:
    CRiskManager()
    {
        m_initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
        m_dailyStartBalance = m_initialBalance;
        m_dailyStartTime = TimeCurrent();
        m_consecutiveLosses = 0;
        m_dailyTrades = 0;
        m_dailyProfit = 0;
    }

    void OnNewDay()
    {
        m_dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
        m_dailyStartTime = TimeCurrent();
        m_dailyTrades = 0;
        m_dailyProfit = 0;
    }

    void OnTradeClose(double profit)
    {
        m_dailyProfit += profit;
        m_dailyTrades++;

        if(profit < 0) m_consecutiveLosses++;
        else m_consecutiveLosses = 0;
    }

    bool CanTrade(double maxDailyLossPct, int maxDailyTrades, int maxConsecutiveLosses)
    {
        // 日次損失チェック
        double dailyLossPct = (m_dailyStartBalance - AccountInfoDouble(ACCOUNT_BALANCE)) / m_dailyStartBalance * 100;
        if(dailyLossPct >= maxDailyLossPct) {
            return false;
        }

        // 日次取引数チェック
        if(m_dailyTrades >= maxDailyTrades) {
            return false;
        }

        // 連敗チェック
        if(m_consecutiveLosses >= maxConsecutiveLosses) {
            return false;
        }

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

        // ロットステップに丸める
        lots = MathFloor(lots / lotStep) * lotStep;
        lots = MathMax(minLot, MathMin(maxLot, lots));

        return lots;
    }

    int GetConsecutiveLosses() const { return m_consecutiveLosses; }
    int GetDailyTrades() const { return m_dailyTrades; }
    double GetDailyProfit() const { return m_dailyProfit; }
};

//+------------------------------------------------------------------+
//| パラメータ                                                       |
//+------------------------------------------------------------------+
input group "===== 秒足設定 ====="
input int      InpSecondsPerBar = 10;        // 秒足期間
input int      InpHistoryBars = 100;         // 履歴保存数

input group "===== EMA設定 ====="
input int      InpEMA_Fast = 3;              // 短期EMA
input int      InpEMA_Slow = 8;              // 長期EMA
input int      InpEMA_Trend = 21;            // トレンドEMA
input ENUM_APPLIED_PRICE InpAppliedPrice = PRICE_CLOSE;

input group "===== マルチタイムフレーム ====="
input bool     InpUseMTF = true;             // MTF分析を使用
input ENUM_TIMEFRAMES InpMTF_Timeframe = PERIOD_M1; // 上位足
input int      InpMTF_EMA_Period = 50;       // 上位足EMA期間

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
input bool     InpAvoidNews = true;          // 重要指標回避

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
input string   InpComment = "SCAL_PRO";      // コメント
input int      InpSlippage = 5;              // スリッページ
input bool     InpShowPanel = true;          // パネル表示
input bool     InpDebugMode = false;         // デバッグモード

//+------------------------------------------------------------------+
//| グローバル変数                                                   |
//+------------------------------------------------------------------+
// データ管理
CRingBuffer<SSecondBar> g_secondBars(100);
SSecondBar g_currentBar;
datetime g_currentBarTime = 0;

// EMA値
double g_emaFast = 0, g_emaSlow = 0, g_emaTrend = 0;
double g_emaFast_prev = 0, g_emaSlow_prev = 0;
double g_mtf_ema = 0;
bool g_emaInitialized = false;

// ATR
double g_atr = 0;

// シグナル
int g_lastSignal = 0;
datetime g_lastSignalTime = 0;

// ポジション管理
ulong g_currentTicket = 0;
int g_currentDirection = 0; // 1=買い, -1=売り
datetime g_lastTradeTime = 0;
double g_lastTradePrice = 0;

// 統計
CStatistics g_stats;
CRiskManager g_risk;

// パフォーマンス
int g_totalTicks = 0;
int g_barsCreated = 0;
datetime g_startTime = 0;

// ブローカー情報
double g_pointMultiplier = 1.0; // 4桁/5桁対応
int g_digits = 0;

// UI
string g_prefix = "SPRO_";

// ログ
int g_logHandle = INVALID_HANDLE;
string g_logFile = "";

// 前回の価格（ボリューム判定用）
double g_lastBid = 0, g_lastAsk = 0;

// 日付チェック用
datetime g_lastDayCheck = 0;

//+------------------------------------------------------------------+
//| 初期化                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
    PrintFormat("========================================");
    PrintFormat("EMA CROSS FOR SCAL PRO v2.0 - 起動");
    PrintFormat("========================================");

    // パラメータ検証
    if(!ValidateParameters()) {
        return INIT_PARAMETERS_INCORRECT;
    }

    // ブローカー情報取得
    InitializeBrokerInfo();

    // Trade設定
    g_trade.SetExpertMagicNumber(InpMagicNumber);
    g_trade.SetDeviationInPoints(InpSlippage);
    g_trade.SetTypeFilling(ORDER_FILLING_FOK);
    g_trade.SetAsyncMode(false);

    // ログファイル作成
    if(InpDebugMode) {
        InitializeLog();
    }

    // 初期化
    g_startTime = TimeCurrent();
    g_lastDayCheck = TimeCurrent();

    MqlTick tick;
    if(SymbolInfoTick(_Symbol, tick)) {
        g_currentBarTime = TimeCurrent();
        g_currentBarTime -= g_currentBarTime % InpSecondsPerBar;
        g_currentBar.Reset(g_currentBarTime, tick.bid);
        g_lastBid = tick.bid;
        g_lastAsk = tick.ask;
    }

    // 初期EMA計算（1分足から）
    InitializeEMAFromHistory();

    // UI作成
    if(InpShowPanel) {
        CreatePanel();
    }

    PrintFormat("初期化完了");
    PrintFormat("シンボル: %s | 秒足: %ds | EMA: %d/%d/%d",
                _Symbol, InpSecondsPerBar, InpEMA_Fast, InpEMA_Slow, InpEMA_Trend);
    PrintFormat("ポイント倍率: %.0f | 桁数: %d", g_pointMultiplier, g_digits);
    PrintFormat("========================================");

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| 終了処理                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    PrintFormat("========================================");
    PrintFormat("EMA CROSS FOR SCAL PRO - 終了");
    PrintFormat("稼働時間: %d秒 | 処理ティック: %d",
                (TimeCurrent() - g_startTime), g_totalTicks);
    PrintFormat("生成秒足: %d本", g_barsCreated);
    PrintFormat("----------------------------------------");
    PrintFormat("【取引統計】");
    PrintFormat("総取引数: %d (勝ち: %d / 負け: %d)",
                g_stats.totalTrades, g_stats.winTrades, g_stats.loseTrades);
    PrintFormat("勝率: %.2f%%", g_stats.GetWinRate());
    PrintFormat("プロフィットファクター: %.2f", g_stats.GetProfitFactor());
    PrintFormat("期待値: %.2f", g_stats.GetExpectancy());
    PrintFormat("シャープレシオ: %.2f", g_stats.GetSharpeRatio());
    PrintFormat("最大DD: %.2f%%", g_stats.GetMaxDrawdown());
    PrintFormat("総損益: %.2f", g_stats.totalProfit);
    PrintFormat("========================================");

    // オブジェクト削除
    ObjectsDeleteAll(0, g_prefix);

    // ログクローズ
    if(g_logHandle != INVALID_HANDLE) {
        FileClose(g_logHandle);
    }
}

//+------------------------------------------------------------------+
//| ティック処理                                                     |
//+------------------------------------------------------------------+
void OnTick()
{
    g_totalTicks++;

    // ティック取得
    MqlTick tick;
    if(!SymbolInfoTick(_Symbol, tick)) return;

    // 新しい日のチェック
    CheckNewDay();

    // 現在時刻
    datetime currentTime = TimeCurrent();
    datetime barTime = currentTime - (currentTime % InpSecondsPerBar);

    // 新しいバーの開始
    if(barTime > g_currentBarTime) {
        // 前のバーを確定
        FinalizeBar();

        // 新しいバーを開始
        g_currentBarTime = barTime;
        g_currentBar.Reset(barTime, tick.bid);
        g_barsCreated++;

        // EMA計算
        CalculateEMA();

        // シグナル検出
        if(g_emaInitialized) {
            int signal = DetectSignal();
            if(signal != 0) {
                ProcessSignal(signal);
            }
        }
    } else {
        // 現在バーを更新
        bool isBuy = (tick.bid >= g_lastBid); // 上昇ティックなら買い
        g_currentBar.Update(tick.bid, tick.volume, isBuy);
    }

    g_lastBid = tick.bid;
    g_lastAsk = tick.ask;

    // トレイリング
    if(InpUseTrailing && g_currentTicket > 0) {
        UpdateTrailingStop();
    }

    // UI更新（10ティックに1回）
    if(g_totalTicks % 10 == 0 && InpShowPanel) {
        UpdatePanel();
    }
}

//+------------------------------------------------------------------+
//| パラメータ検証                                                   |
//+------------------------------------------------------------------+
bool ValidateParameters()
{
    if(InpSecondsPerBar < 1 || InpSecondsPerBar > 60) {
        Print("エラー: 秒足期間は1-60秒");
        return false;
    }

    if(InpEMA_Fast >= InpEMA_Slow || InpEMA_Slow >= InpEMA_Trend) {
        Print("エラー: EMA期間は Fast < Slow < Trend");
        return false;
    }

    if(InpRiskPercent <= 0 || InpRiskPercent > 10) {
        Print("エラー: リスク%は0-10%");
        return false;
    }

    if(InpMaxDailyLoss <= 0 || InpMaxDailyLoss > 20) {
        Print("エラー: 最大日次損失は0-20%");
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

    // 5桁ブローカーの場合、ポイント倍率は10
    if(g_digits == 5 || g_digits == 3) {
        g_pointMultiplier = 10.0;
    } else {
        g_pointMultiplier = 1.0;
    }

    PrintFormat("ブローカー情報: 桁数=%d, ポイント=%.5f, 倍率=%.0f",
                g_digits, _Point, g_pointMultiplier);
}

//+------------------------------------------------------------------+
//| ログ初期化                                                       |
//+------------------------------------------------------------------+
void InitializeLog()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);

    g_logFile = StringFormat("SCAL_PRO_%s_%04d%02d%02d.csv",
                             _Symbol, dt.year, dt.mon, dt.day);

    g_logHandle = FileOpen(g_logFile, FILE_WRITE | FILE_CSV | FILE_ANSI);

    if(g_logHandle != INVALID_HANDLE) {
        FileWrite(g_logHandle, "Time", "Type", "Price", "SL", "TP",
                  "Profit", "Balance", "Signal", "EMAFast", "EMASlow", "ATR");
        FileClose(g_logHandle);
        PrintFormat("ログファイル作成: %s", g_logFile);
    }
}

//+------------------------------------------------------------------+
//| ログ書き込み                                                     |
//+------------------------------------------------------------------+
void WriteLog(string type, double price, double sl, double tp,
              double profit, int signal)
{
    if(!InpDebugMode || g_logFile == "") return;

    int handle = FileOpen(g_logFile, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_READ);
    if(handle == INVALID_HANDLE) return;

    FileSeek(handle, 0, SEEK_END);
    FileWrite(handle,
              TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
              type, price, sl, tp, profit,
              AccountInfoDouble(ACCOUNT_BALANCE),
              signal, g_emaFast, g_emaSlow, g_atr);

    FileClose(handle);
}

//+------------------------------------------------------------------+
//| 1分足からEMA初期化                                               |
//+------------------------------------------------------------------+
void InitializeEMAFromHistory()
{
    // 1分足を取得
    double close[];
    ArraySetAsSeries(close, true);

    int needed = MathMax(InpEMA_Trend, InpMTF_EMA_Period) * 2;
    int copied = CopyClose(_Symbol, PERIOD_M1, 0, needed, close);

    if(copied < InpEMA_Trend) {
        PrintFormat("警告: 履歴データ不足 (%d本) - リアルタイムから初期化", copied);
        if(copied > 0) {
            g_emaFast = close[0];
            g_emaSlow = close[0];
            g_emaTrend = close[0];
        }
        return;
    }

    // SMAで初期化
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
    PrintFormat("EMA初期化完了: Fast=%.5f, Slow=%.5f, Trend=%.5f",
                g_emaFast, g_emaSlow, g_emaTrend);
}

//+------------------------------------------------------------------+
//| バー確定                                                         |
//+------------------------------------------------------------------+
void FinalizeBar()
{
    g_secondBars.Push(g_currentBar);

    if(InpDebugMode && g_barsCreated % 60 == 0) {
        PrintFormat("[BAR] Time:%s O:%.5f H:%.5f L:%.5f C:%.5f V:%I64d T:%I64d BV:%I64d SV:%I64d",
                    TimeToString(g_currentBar.time, TIME_SECONDS),
                    g_currentBar.open, g_currentBar.high,
                    g_currentBar.low, g_currentBar.close,
                    g_currentBar.volume, g_currentBar.tickCount,
                    g_currentBar.buyVolume, g_currentBar.sellVolume);
    }
}

//+------------------------------------------------------------------+
//| EMA計算                                                          |
//+------------------------------------------------------------------+
void CalculateEMA()
{
    SSecondBar bar;
    if(!g_secondBars.Get(0, bar)) return;

    double price = GetPrice(bar);

    // 前回値を保存
    g_emaFast_prev = g_emaFast;
    g_emaSlow_prev = g_emaSlow;

    // EMA更新
    double alphaFast = 2.0 / (InpEMA_Fast + 1.0);
    double alphaSlow = 2.0 / (InpEMA_Slow + 1.0);
    double alphaTrend = 2.0 / (InpEMA_Trend + 1.0);

    g_emaFast = price * alphaFast + g_emaFast * (1.0 - alphaFast);
    g_emaSlow = price * alphaSlow + g_emaSlow * (1.0 - alphaSlow);
    g_emaTrend = price * alphaTrend + g_emaTrend * (1.0 - alphaTrend);

    // ATR計算
    CalculateATR();

    // MTF更新
    if(InpUseMTF && g_totalTicks % 100 == 0) {
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
//| 価格取得                                                         |
//+------------------------------------------------------------------+
double GetPrice(const SSecondBar &bar)
{
    switch(InpAppliedPrice) {
        case PRICE_OPEN: return bar.open;
        case PRICE_HIGH: return bar.high;
        case PRICE_LOW: return bar.low;
        case PRICE_CLOSE: return bar.close;
        case PRICE_MEDIAN: return (bar.high + bar.low) / 2.0;
        case PRICE_TYPICAL: return (bar.high + bar.low + bar.close) / 3.0;
        case PRICE_WEIGHTED: return (bar.high + bar.low + 2 * bar.close) / 4.0;
    }
    return bar.close;
}

//+------------------------------------------------------------------+
//| シグナル検出                                                     |
//+------------------------------------------------------------------+
int DetectSignal()
{
    if(g_secondBars.Size() < 2) return 0;

    // クロス検出
    double diff_current = g_emaFast - g_emaSlow;
    double diff_prev = g_emaFast_prev - g_emaSlow_prev;

    // クロス強度チェック
    double crossStrength = MathAbs(diff_current) / _Point / g_pointMultiplier;
    if(crossStrength < InpMinCrossStrength) return 0;

    int signal = 0;

    // ゴールデンクロス
    if(diff_prev <= 0 && diff_current > 0) {
        signal = 1;
    }
    // デッドクロス
    else if(diff_prev >= 0 && diff_current < 0) {
        signal = -1;
    }

    if(signal == 0) return 0;

    // フィルター適用
    if(!PassFilters(signal)) {
        if(InpDebugMode) {
            PrintFormat("[FILTERED] Signal=%d", signal);
        }
        return 0;
    }

    return signal;
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
        if(spread > InpMaxSpreadPips) {
            if(InpDebugMode) PrintFormat("[FILTER] Spread=%.2f", spread);
            return false;
        }
    }

    // ATRフィルター
    if(InpUseATRFilter && g_atr > 0) {
        double atrPips = g_atr / _Point / g_pointMultiplier;
        if(atrPips < InpMinATR_Pips || atrPips > InpMaxATR_Pips) {
            if(InpDebugMode) PrintFormat("[FILTER] ATR=%.2f", atrPips);
            return false;
        }
    }

    // トレンドフィルター
    if(InpUseTrendFilter) {
        if(signal == 1 && g_emaFast < g_emaTrend) {
            if(InpDebugMode) Print("[FILTER] Buy but below trend EMA");
            return false;
        }
        if(signal == -1 && g_emaFast > g_emaTrend) {
            if(InpDebugMode) Print("[FILTER] Sell but above trend EMA");
            return false;
        }
    }

    // MTFフィルター
    if(InpUseMTF && g_mtf_ema > 0) {
        if(signal == 1 && tick.bid < g_mtf_ema) {
            if(InpDebugMode) Print("[FILTER] Buy but below MTF EMA");
            return false;
        }
        if(signal == -1 && tick.bid > g_mtf_ema) {
            if(InpDebugMode) Print("[FILTER] Sell but above MTF EMA");
            return false;
        }
    }

    // ボリュームフィルター
    if(InpUseVolumeFilter) {
        SSecondBar bar;
        if(g_secondBars.Get(0, bar)) {
            double totalVol = (double)(bar.buyVolume + bar.sellVolume);
            if(totalVol > 0) {
                double buyRatio = (double)bar.buyVolume / totalVol;
                double sellRatio = (double)bar.sellVolume / totalVol;

                if(signal == 1 && buyRatio < InpMinVolumeDelta) {
                    if(InpDebugMode) PrintFormat("[FILTER] Buy volume ratio=%.2f", buyRatio);
                    return false;
                }
                if(signal == -1 && sellRatio < InpMinVolumeDelta) {
                    if(InpDebugMode) PrintFormat("[FILTER] Sell volume ratio=%.2f", sellRatio);
                    return false;
                }
            }
        }
    }

    // 時間帯フィルター
    if(InpUseTimeFilter) {
        MqlDateTime dt;
        TimeToStruct(TimeCurrent(), dt);

        if(dt.hour < InpStartHour || dt.hour >= InpEndHour) {
            if(InpDebugMode) PrintFormat("[FILTER] Outside trading hours: %d", dt.hour);
            return false;
        }
    }

    return true;
}

//+------------------------------------------------------------------+
//| シグナル処理                                                     |
//+------------------------------------------------------------------+
void ProcessSignal(int signal)
{
    // リスク管理チェック
    if(!g_risk.CanTrade(InpMaxDailyLoss, InpMaxDailyTrades, InpMaxConsecLosses)) {
        if(InpDebugMode) {
            PrintFormat("[RISK] Trading disabled. DailyTrades=%d, ConsecLosses=%d",
                        g_risk.GetDailyTrades(), g_risk.GetConsecutiveLosses());
        }
        return;
    }

    // 取引間隔チェック
    if(g_lastTradeTime > 0) {
        int elapsed = (int)(TimeCurrent() - g_lastTradeTime);
        if(elapsed < InpMinTradeIntervalSec) {
            if(InpDebugMode) {
                PrintFormat("[INTERVAL] Too soon. Elapsed=%ds", elapsed);
            }
            return;
        }
    }

    // 反対ポジションを決済
    if(InpCloseOpposite && g_currentDirection != 0 && g_currentDirection != signal) {
        ClosePosition();
    }

    // 同方向ポジションが既にある場合はスキップ
    if(g_currentDirection == signal) {
        if(InpDebugMode) {
            PrintFormat("[SKIP] Already in position: %d", signal);
        }
        return;
    }

    // 取引実行
    OpenPosition(signal);
}

//+------------------------------------------------------------------+
//| ポジションオープン                                               |
//+------------------------------------------------------------------+
void OpenPosition(int signal)
{
    MqlTick tick;
    if(!SymbolInfoTick(_Symbol, tick)) return;

    // ロット計算
    double lots;
    if(InpUseDynamicLots) {
        double slPips = CalculateSL_Pips();
        lots = g_risk.CalculateLotSize(InpRiskPercent, slPips,
                                        AccountInfoDouble(ACCOUNT_BALANCE));
    } else {
        lots = InpFixedLots;
    }

    // SL/TP計算
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

    // 注文
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
        g_lastTradePrice = entryPrice;

        double slPips = (sl > 0) ? MathAbs(entryPrice - sl) / _Point / g_pointMultiplier : 0;
        double tpPips = (tp > 0) ? MathAbs(tp - entryPrice) / _Point / g_pointMultiplier : 0;

        PrintFormat("[OPEN] %s | Lots:%.2f | Price:%.5f | SL:%.1fpips | TP:%.1fpips | Ticket:%I64u",
                    (signal == 1 ? "BUY" : "SELL"), lots, entryPrice, slPips, tpPips, g_currentTicket);

        WriteLog("OPEN", entryPrice, sl, tp, 0, signal);

        if(InpShowPanel) {
            DrawSignal(signal, entryPrice);
        }
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
        // ポジションが既に無い（SL/TPで決済済み）
        CheckClosedPosition();
        return;
    }

    double profit = PositionGetDouble(POSITION_PROFIT);

    if(g_trade.PositionClose(g_currentTicket)) {
        PrintFormat("[CLOSE] Ticket:%I64u | Profit:%.2f", g_currentTicket, profit);

        // 統計更新
        g_stats.AddTrade(profit, AccountInfoDouble(ACCOUNT_BALANCE));
        g_risk.OnTradeClose(profit);

        WriteLog("CLOSE", PositionGetDouble(POSITION_PRICE_CURRENT), 0, 0, profit, 0);

        g_currentTicket = 0;
        g_currentDirection = 0;
    }
}

//+------------------------------------------------------------------+
//| 決済済みポジションチェック（SL/TP）                              |
//+------------------------------------------------------------------+
void CheckClosedPosition()
{
    if(g_currentTicket == 0) return;

    // 履歴から検索
    if(HistorySelectByPosition(g_currentTicket)) {
        int deals = HistoryDealsTotal();

        for(int i = deals - 1; i >= 0; i--) {
            ulong dealTicket = HistoryDealGetTicket(i);
            if(dealTicket == 0) continue;

            if(HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID) == g_currentTicket) {
                double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);

                PrintFormat("[CLOSED] Ticket:%I64u | Profit:%.2f (SL/TP)",
                            g_currentTicket, profit);

                // 統計更新
                g_stats.AddTrade(profit, AccountInfoDouble(ACCOUNT_BALANCE));
                g_risk.OnTradeClose(profit);

                WriteLog("AUTO_CLOSE", HistoryDealGetDouble(dealTicket, DEAL_PRICE),
                         0, 0, profit, 0);

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
        if(g_trade.PositionModify(g_currentTicket, newSL, currentTP)) {
            if(InpDebugMode) {
                PrintFormat("[TRAIL] Ticket:%I64u | New SL:%.5f", g_currentTicket, newSL);
            }
        }
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
        PrintFormat("========== 新しい日: %04d-%02d-%02d ==========",
                    dtNow.year, dtNow.mon, dtNow.day);

        g_risk.OnNewDay();
        g_lastDayCheck = TimeCurrent();
    }
}

//+------------------------------------------------------------------+
//| パネル作成                                                       |
//+------------------------------------------------------------------+
void CreatePanel()
{
    int width = 380;
    int height = 420;

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
//| パネル更新                                                       |
//+------------------------------------------------------------------+
void UpdatePanel()
{
    string lines[];
    color colors[];
    ArrayResize(lines, 22);
    ArrayResize(colors, 22);

    MqlTick tick;
    SymbolInfoTick(_Symbol, tick);

    double spread = (tick.ask - tick.bid) / _Point / g_pointMultiplier;
    double atrPips = g_atr / _Point / g_pointMultiplier;
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);

    int idx = 0;

    lines[idx] = "═══ EMA CROSS SCAL PRO ═══";
    colors[idx++] = clrGold;

    lines[idx] = StringFormat("%s | %ds足 | バー:%d", _Symbol, InpSecondsPerBar, g_secondBars.Size());
    colors[idx++] = clrWhite;

    lines[idx] = "───────────────────";
    colors[idx++] = clrGray;

    lines[idx] = StringFormat("Fast EMA(%d): %.5f", InpEMA_Fast, g_emaFast);
    colors[idx++] = clrAqua;

    lines[idx] = StringFormat("Slow EMA(%d): %.5f", InpEMA_Slow, g_emaSlow);
    colors[idx++] = clrMagenta;

    lines[idx] = StringFormat("差分: %+.5f (%.2fpips)",
                              g_emaFast - g_emaSlow,
                              (g_emaFast - g_emaSlow) / _Point / g_pointMultiplier);
    colors[idx++] = (g_emaFast > g_emaSlow) ? clrLime : clrRed;

    lines[idx] = StringFormat("Trend EMA(%d): %.5f", InpEMA_Trend, g_emaTrend);
    colors[idx++] = clrYellow;

    lines[idx] = "───────────────────";
    colors[idx++] = clrGray;

    lines[idx] = StringFormat("ATR: %.2f pips", atrPips);
    colors[idx++] = (atrPips >= InpMinATR_Pips && atrPips <= InpMaxATR_Pips) ? clrLime : clrOrange;

    lines[idx] = StringFormat("スプレッド: %.1f pips", spread);
    colors[idx++] = (spread <= InpMaxSpreadPips) ? clrLime : clrRed;

    lines[idx] = "───────────────────";
    colors[idx++] = clrGray;

    lines[idx] = StringFormat("ポジション: %s",
                              g_currentDirection == 1 ? "買い" :
                              g_currentDirection == -1 ? "売り" : "なし");
    colors[idx++] = g_currentDirection == 1 ? clrLime :
                    g_currentDirection == -1 ? clrRed : clrGray;

    if(g_currentTicket > 0 && PositionSelectByTicket(g_currentTicket)) {
        double profit = PositionGetDouble(POSITION_PROFIT);
        lines[idx] = StringFormat("含み損益: %.2f", profit);
        colors[idx++] = profit >= 0 ? clrLime : clrRed;
    } else {
        lines[idx] = "含み損益: ---";
        colors[idx++] = clrGray;
    }

    lines[idx] = "───────────────────";
    colors[idx++] = clrGray;

    lines[idx] = StringFormat("取引: %dW-%dL (%.1f%%)",
                              g_stats.winTrades, g_stats.loseTrades,
                              g_stats.GetWinRate());
    colors[idx++] = clrWhite;

    lines[idx] = StringFormat("PF: %.2f | 期待値: %.2f",
                              g_stats.GetProfitFactor(),
                              g_stats.GetExpectancy());
    colors[idx++] = clrCyan;

    lines[idx] = StringFormat("Sharpe: %.2f | MaxDD: %.2f%%",
                              g_stats.GetSharpeRatio(),
                              g_stats.GetMaxDrawdown());
    colors[idx++] = clrCyan;

    lines[idx] = StringFormat("総損益: %.2f", g_stats.totalProfit);
    colors[idx++] = g_stats.totalProfit >= 0 ? clrLime : clrRed;

    lines[idx] = "───────────────────";
    colors[idx++] = clrGray;

    lines[idx] = StringFormat("口座: %.2f | 有効: %.2f", balance, equity);
    colors[idx++] = clrWhite;

    lines[idx] = StringFormat("本日: %d取引 | 連敗: %d",
                              g_risk.GetDailyTrades(),
                              g_risk.GetConsecutiveLosses());
    colors[idx++] = g_risk.GetConsecutiveLosses() >= 3 ? clrOrange : clrGray;

    lines[idx] = "───────────────────";
    colors[idx++] = clrGray;

    lines[idx] = StringFormat("Tick: %d | 稼働: %ds",
                              g_totalTicks, (TimeCurrent() - g_startTime));
    colors[idx++] = clrGray;

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
//| シグナル描画                                                     |
//+------------------------------------------------------------------+
void DrawSignal(int signal, double price)
{
    string name = g_prefix + "SIG_" + TimeToString(TimeCurrent(), TIME_SECONDS);

    ObjectCreate(0, name, signal == 1 ? OBJ_ARROW_BUY : OBJ_ARROW_SELL,
                 0, TimeCurrent(), price);
    ObjectSetInteger(0, name, OBJPROP_COLOR, signal == 1 ? clrLime : clrRed);
    ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
}
//+------------------------------------------------------------------+