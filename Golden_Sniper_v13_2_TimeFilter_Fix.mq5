//+------------------------------------------------------------------+
//|                           Golden_Sniper_v13_2_TimeFilter_Fix.mq5 |
//|            XAUUSD専用 - 超攻撃的スキャルピング (時間指定版)      |
//|            Base: v13.1 (PF 8.09 Setting)                         |
//|            Feature: Time Filter (15:00 - 19:00)                  |
//|            Fix: IsTradingTime Function for MQL5                  |
//|                                              Copyright 2025      |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025"
#property link      ""
#property version   "13.21"
#property description "Golden Sniper v13.2 TimeFilter Fix"
#property description "Trading Hours: 15:00 - 19:00 (Server Time)"
#property description "PF 8.09 Optimized Parameters"

#include <Trade\Trade.mqh>
CTrade g_trade;

//+------------------------------------------------------------------+
//| 時間足設定                                                       |
//+------------------------------------------------------------------+
enum CUSTOM_TIMEFRAME
{
    TF_S5  = 5, TF_S10 = 10, TF_S15 = 15, TF_S30 = 30,
    TF_M1  = 60, TF_M3 = 180, TF_M5 = 300, TF_M10 = 600,
    TF_M15 = 900, TF_M30 = 1800, TF_H1 = 3600, TF_H4 = 14400
};

enum LOT_CALCULATION_MODE
{
    LOT_FIXED = 0,          // 固定ロット
    LOT_MARGIN_LEVEL = 1    // 余剰証拠金連動
};

//+------------------------------------------------------------------+
//| パラメータ設定                                                   |
//+------------------------------------------------------------------+
input group "===== 時間フィルター (NEW) ====="
input bool     InpUseTimeFilter = true;    // 時間フィルターを使う
input int      InpStartHour     = 15;      // 開始時間 (サーバー時間)
input int      InpEndHour       = 19;      // 終了時間 (サーバー時間)

input group "===== 時間足 & フィルター ====="
input CUSTOM_TIMEFRAME InpCustomTimeframe = TF_S5; // 5秒足
input double   InpMaxSpreadPips = 3.0;             // スプレッドフィルター

input group "===== ADX Filter (Fast) ====="
input bool     InpUseADXFilter = true;
input int      InpADX_Period = 5;
input double   InpADX_Threshold = 16.0;
input bool     InpADX_RisingOnly = true;

input group "===== EMA & ATR設定 ====="
input int      InpEMA_Fast = 3;
input int      InpEMA_Standard = 10;
input int      InpATR_Period = 14;

input group "===== 初回エントリー設定 ====="
input double   InpSL2_Offset_Percent = 0.004;

input group "===== パターンC (早期防衛) ====="
input bool     InpUsePatC = true;
input double   InpPatC_Trigger = 0.075;
input double   InpPatC_Offset  = 0.00;

input group "===== パターンD (建値+微益) ====="
input bool     InpUsePatD = true;
input double   InpPatD_Trigger = 1.05;
input double   InpPatD_Offset  = 0.023;

input group "===== パターンE (利益確保 - OFF) ====="
input bool     InpUsePatE = false;
input double   InpPatE_Trigger = 1.00;
input double   InpPatE_Div_Trend = 3.0;
input double   InpPatE_Div_Counter = 2.0;

input group "===== パターンF (TP1ロック) ====="
input bool     InpUsePatF = true;
input double   InpPatF_ATR_Mult = 3.0;
input int      InpPatF_Bars = 5;

input group "===== パターンG (トレーリング最大) ====="
input bool     InpUsePatG = true;
input double   InpPatG_Ratio = 95.5;

input group "===== ロット設定 ====="
input LOT_CALCULATION_MODE InpLotMode = LOT_MARGIN_LEVEL;
input double   InpFixedLots = 0.01;
input double   InpTargetMarginLevel = 1500.0; // 安全運用推奨値
input double   InpMinLots = 0.01;
input double   InpMaxLots = 10.0;

input group "===== リスク管理 ====="
input int      InpMaxConsecutiveLosses = 4;
input int      InpCoolingPeriodMinutes = 30; // 安全運用推奨値

input group "===== 表示設定 ====="
input bool     InpShowInfoPanel = true;
input bool     InpShowEMALines = true;
input bool     InpShowEMAFill = true;

input group "===== その他 ====="
input int      InpMagicNumber = 230017;      // v13.2
input string   InpComment = "Golden_Sniper_v13.2";

//+------------------------------------------------------------------+
//| グローバル変数                                                   |
//+------------------------------------------------------------------+
struct CustomBar { datetime time; double open; double high; double low; double close; long volume; };
CustomBar g_customBars[];
int g_customBarCount = 0;
datetime g_lastCustomBarTime = 0;

// Indicators
double g_emaFast = 0, g_emaStandard = 0;
double g_emaFast_prev = 0, g_emaStandard_prev = 0;
double g_htfEmaFast = 0, g_htfEmaStandard = 0;
double g_adx = 0;

// Confirmed Values
double g_prevConfirmedEmaFast = 0, g_prevConfirmedEmaStandard = 0;
double g_prevConfirmedHtfEmaFast = 0, g_prevConfirmedHtfEmaStandard = 0;
double g_prevConfirmedADX = 0;
double g_prev2ConfirmedADX = 0;
bool   g_isEmaInitialized = false;

int g_hEmaFast, g_hEmaStd, g_hAtr, g_hHtfEmaFast, g_hHtfEmaStd, g_hAdx;
double g_atr = 0;
CUSTOM_TIMEFRAME g_htfTimeframe;

ulong g_ticket = 0;
int g_direction = 0;
datetime g_entryTime = 0;
int g_entryBarIndex = 0;
double g_entryPrice = 0;
double g_sl1_price = 0, g_sl2_price = 0, g_initial_risk = 0;
double g_f1sl_price = 0, g_f2sl_price = 0, g_f3sl_price = 0, g_current_sl = 0, g_tp2_price = 0;
bool g_early_be_set = false, g_breakeven_set = false, g_f2sl_set = false, g_f3sl_set = false;
bool g_htf_same_direction = false;
double g_highest_price = 0, g_lowest_price = 0;
int g_consecutive_losses = 0;
datetime g_trading_stopped_at = 0;
bool g_trading_active = true;
int g_totalTrades = 0, g_wins = 0;
double g_profit = 0;
datetime g_lastBarTime = 0;
int g_digits = 0;
string g_panelPrefix, g_emaLinePrefix, g_emaFillPrefix;
bool g_useSecondTimeframe = false;

//+------------------------------------------------------------------+
//| 初期化処理                                                       |
//+------------------------------------------------------------------+
int OnInit()
{
    g_panelPrefix   = "InfoPanel_" + IntegerToString(InpMagicNumber) + "_";
    g_emaLinePrefix = "EMALine_" + IntegerToString(InpMagicNumber) + "_";
    g_emaFillPrefix = "EMAFill_" + IntegerToString(InpMagicNumber) + "_";

    Print("========================================");
    Print("GOLDEN SNIPER v13.2 TIME FILTER FIX");
    Print("Time: " + IntegerToString(InpStartHour) + ":00 - " + IntegerToString(InpEndHour) + ":00");
    Print("========================================");

    g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    g_useSecondTimeframe = (InpCustomTimeframe < TF_M1);

    if(g_useSecondTimeframe) ArrayResize(g_customBars, 1000);
    g_htfTimeframe = GetHigherTimeframe(InpCustomTimeframe);

    g_trade.SetExpertMagicNumber(InpMagicNumber);
    g_trade.SetTypeFilling(ORDER_FILLING_RETURN);
    g_trade.SetAsyncMode(false);

    ENUM_TIMEFRAMES mt5_tf = CustomToMT5Timeframe(InpCustomTimeframe);
    ENUM_TIMEFRAMES htf_mt5 = CustomToMT5Timeframe(g_htfTimeframe);

    g_hEmaFast = iMA(_Symbol, mt5_tf, InpEMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
    g_hEmaStd  = iMA(_Symbol, mt5_tf, InpEMA_Standard, 0, MODE_EMA, PRICE_CLOSE);
    g_hAtr     = iATR(_Symbol, mt5_tf, InpATR_Period);
    g_hHtfEmaFast = iMA(_Symbol, htf_mt5, InpEMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
    g_hHtfEmaStd  = iMA(_Symbol, htf_mt5, InpEMA_Standard, 0, MODE_EMA, PRICE_CLOSE);
    g_hAdx     = iADX(_Symbol, mt5_tf, InpADX_Period);

    if(g_hEmaFast == INVALID_HANDLE || g_hEmaStd == INVALID_HANDLE || g_hAtr == INVALID_HANDLE || g_hAdx == INVALID_HANDLE) return INIT_FAILED;

    RecoverPosition();
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    DeleteInfoPanel(); DeleteEMALines(); DeleteEMAFill();
    IndicatorRelease(g_hEmaFast); IndicatorRelease(g_hEmaStd);
    IndicatorRelease(g_hAtr); IndicatorRelease(g_hHtfEmaFast); IndicatorRelease(g_hHtfEmaStd); IndicatorRelease(g_hAdx);
}

void RecoverPosition()
{
    g_ticket = 0; g_direction = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if(ticket > 0) {
            if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber && PositionGetString(POSITION_SYMBOL) == _Symbol) {
                g_ticket = ticket;
                long type = PositionGetInteger(POSITION_TYPE);
                g_direction = (type == POSITION_TYPE_BUY) ? 1 : -1;
                g_entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
                g_current_sl = PositionGetDouble(POSITION_SL);
                return;
            }
        }
    }
}

bool CheckTradingAllowed()
{
    if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED)) return false;
    return true;
}

//+------------------------------------------------------------------+
//| 時間フィルター判定 (MQL5対応版)                                  |
//+------------------------------------------------------------------+
bool IsTradingTime()
{
    if(!InpUseTimeFilter) return true;

    MqlDateTime tm;
    TimeCurrent(tm);
    int currentHour = tm.hour;

    // 指定した時間内 (Start <= Hour < End) であればTrue
    if(currentHour >= InpStartHour && currentHour < InpEndHour) return true;

    return false;
}

//+------------------------------------------------------------------+
//| メイン処理                                                       |
//+------------------------------------------------------------------+
void OnTick()
{
    if(!CheckTradingAllowed()) {
        if(InpShowInfoPanel) UpdateInfoPanel();
        return;
    }
    CheckTradingResume();

    MqlTick tick;
    if(!SymbolInfoTick(_Symbol, tick)) return;

    double currentSpreadPips = (tick.ask - tick.bid) / _Point / 10.0;
    if(g_digits == 3) currentSpreadPips = (tick.ask - tick.bid) / _Point / 100.0;

    if(currentSpreadPips > InpMaxSpreadPips) {
        if(InpShowInfoPanel) UpdateInfoPanel();
        if(g_ticket > 0) { CheckF2SL(); CheckTP2Exit(); } // スプレッドフィルター時も決済は監視
        return;
    }

    bool isNewBar = false;
    datetime currentBarTime = 0;

    if(g_useSecondTimeframe) {
        UpdateCustomBars();
        int requiredBars = InpEMA_Standard + 1 + InpADX_Period * 2;
        if(g_customBarCount < requiredBars) {
            if(InpShowInfoPanel) UpdateInfoPanel();
            return;
        }

        if(!g_isEmaInitialized) {
            CalculateCustomIndicators();
            g_lastBarTime = g_customBars[g_customBarCount - 1].time;
            return;
        }

        currentBarTime = g_customBars[g_customBarCount - 1].time;

        if(currentBarTime != g_lastBarTime) {
            if(g_lastBarTime != 0) {
                g_prevConfirmedEmaFast = g_emaFast;
                g_prevConfirmedEmaStandard = g_emaStandard;
                g_prevConfirmedHtfEmaFast = g_htfEmaFast;
                g_prevConfirmedHtfEmaStandard = g_htfEmaStandard;

                g_prev2ConfirmedADX = g_prevConfirmedADX;
                g_prevConfirmedADX = g_adx;

                g_emaFast_prev = g_prevConfirmedEmaFast;
                g_emaStandard_prev = g_prevConfirmedEmaStandard;
            }
            g_lastBarTime = currentBarTime;
            isNewBar = true;

            // ★時間フィルター適用
            if(IsTradingTime()) {
                int signal = DetectSignalStateful();
                ProcessNewBar(signal, currentBarTime, true);
            }
        }
        CalculateCustomIndicators();

    } else {
        ENUM_TIMEFRAME mt5_tf = CustomToMT5Timeframe(InpCustomTimeframe);
        currentBarTime = iTime(_Symbol, mt5_tf, 0);
        if(currentBarTime != g_lastBarTime) {
            g_lastBarTime = currentBarTime;
            isNewBar = true;
            if(!GetIndicatorDataMT5(mt5_tf)) return;

            // ★時間フィルター適用
            if(IsTradingTime()) {
                int signal = DetectSignal();
                ProcessNewBar(signal, currentBarTime, false);
            }
        }
    }

    // ポジション管理は時間外でも常に行う
    if(g_ticket > 0) {
        CheckF2SL();
        ManagePosition();
        CheckTP2Exit();
    }
    if(InpShowInfoPanel) UpdateInfoPanel();
}

//+------------------------------------------------------------------+
//| カスタムバー更新                                                 |
//+------------------------------------------------------------------+
void UpdateCustomBars() {
    MqlTick tick;
    if(!SymbolInfoTick(_Symbol,tick)) return;

    double currentPrice = tick.last;
    if(currentPrice <= 0.0) currentPrice = tick.bid;

    int barSec = (int)InpCustomTimeframe;
    datetime barTime = (tick.time/barSec)*barSec;

    if(g_customBarCount==0 || g_customBars[g_customBarCount-1].time!=barTime) {
        if(g_customBarCount>=ArraySize(g_customBars)) ArrayResize(g_customBars,g_customBarCount+100);
        if(g_customBarCount>2000) { ArrayRemove(g_customBars,0,500); g_customBarCount-=500; }
        g_customBars[g_customBarCount].time=barTime;
        g_customBars[g_customBarCount].open=currentPrice;
        g_customBars[g_customBarCount].high=currentPrice;
        g_customBars[g_customBarCount].low=currentPrice;
        g_customBars[g_customBarCount].close=currentPrice;
        g_customBarCount++;
    } else {
        int i=g_customBarCount-1;
        if(currentPrice > g_customBars[i].high) g_customBars[i].high=currentPrice;
        if(currentPrice < g_customBars[i].low) g_customBars[i].low=currentPrice;
        g_customBars[i].close=currentPrice;
    }
}

//+------------------------------------------------------------------+
//| カスタム指標計算                                                 |
//+------------------------------------------------------------------+
void CalculateCustomIndicators() {
    if(g_customBarCount==0) return;
    double c = g_customBars[g_customBarCount-1].close;

    if(!g_isEmaInitialized) {
        g_prevConfirmedEmaFast = c; g_prevConfirmedEmaStandard = c;
        g_prevConfirmedHtfEmaFast = c; g_prevConfirmedHtfEmaStandard = c;
        g_emaFast = c; g_emaStandard = c; g_htfEmaFast = c; g_htfEmaStandard = c;
        g_isEmaInitialized = true;
        return;
    }

    double alphaFast = 2.0 / (InpEMA_Fast + 1.0);
    g_emaFast = (c - g_prevConfirmedEmaFast) * alphaFast + g_prevConfirmedEmaFast;

    double alphaStd = 2.0 / (InpEMA_Standard + 1.0);
    g_emaStandard = (c - g_prevConfirmedEmaStandard) * alphaStd + g_prevConfirmedEmaStandard;

    g_atr = CalculateATR(InpATR_Period, g_customBarCount-1);
    g_adx = CalculateWilderADX(InpADX_Period, g_customBarCount-1);

    int mult = (int)g_htfTimeframe / (int)InpCustomTimeframe; if(mult < 1) mult = 4;
    double alphaHtfFast = 2.0 / ((InpEMA_Fast * mult) + 1.0);
    g_htfEmaFast = (c - g_prevConfirmedHtfEmaFast) * alphaHtfFast + g_prevConfirmedHtfEmaFast;

    double alphaHtfStd = 2.0 / ((InpEMA_Standard * mult) + 1.0);
    g_htfEmaStandard = (c - g_prevConfirmedHtfEmaStandard) * alphaHtfStd + g_prevConfirmedHtfEmaStandard;
}

//+------------------------------------------------------------------+
//| Wilder's ADX Calculation                                         |
//+------------------------------------------------------------------+
double CalculateWilderADX(int period, int currentIndex) {
    if(currentIndex < period * 2) return 0;

    int startIdx = currentIndex - period * 2;
    if(startIdx <= 0) startIdx = 1;
    if(startIdx > currentIndex) return 0;
    if(currentIndex >= ArraySize(g_customBars)) return 0;

    double smoothTR = 0;
    double smoothDMPlus = 0;
    double smoothDMMinus = 0;

    for(int i = startIdx; i <= currentIndex; i++) {
        double high = g_customBars[i].high;
        double low = g_customBars[i].low;
        double prev_close = g_customBars[i-1].close;
        double prev_high = g_customBars[i-1].high;
        double prev_low = g_customBars[i-1].low;

        double tr = MathMax(high-low, MathMax(MathAbs(high-prev_close), MathAbs(low-prev_close)));
        double dmPlus = (high - prev_high) > (prev_low - low) ? MathMax(high - prev_high, 0) : 0;
        double dmMinus = (prev_low - low) > (high - prev_high) ? MathMax(prev_low - low, 0) : 0;

        if(i == startIdx) {
            smoothTR = tr; smoothDMPlus = dmPlus; smoothDMMinus = dmMinus;
        } else {
            smoothTR = (smoothTR * (period - 1) + tr) / period;
            smoothDMPlus = (smoothDMPlus * (period - 1) + dmPlus) / period;
            smoothDMMinus = (smoothDMMinus * (period - 1) + dmMinus) / period;
        }
    }

    if(smoothTR == 0) return 0;
    double diPlus = (smoothDMPlus / smoothTR) * 100;
    double diMinus = (smoothDMMinus / smoothTR) * 100;
    double sumDI = diPlus + diMinus;
    double dx = (sumDI == 0) ? 0 : (MathAbs(diPlus - diMinus) / sumDI) * 100;

    return dx;
}

bool GetIndicatorDataMT5(ENUM_TIMEFRAMES tf) {
    double f[],s[],a[],adx[];
    ArraySetAsSeries(f,true); ArraySetAsSeries(s,true); ArraySetAsSeries(a,true); ArraySetAsSeries(adx,true);
    if(CopyBuffer(g_hEmaFast,0,0,2,f)<=0 || CopyBuffer(g_hEmaStd,0,0,2,s)<=0 || CopyBuffer(g_hAtr,0,0,1,a)<=0) return false;
    if(CopyBuffer(g_hAdx,0,0,3,adx)<=0) return false;

    g_emaFast_prev=f[1]; g_emaStandard_prev=s[1]; g_emaFast=f[0]; g_emaStandard=s[0]; g_atr=a[0];
    g_adx = adx[1];
    g_prevConfirmedADX = adx[1];
    g_prev2ConfirmedADX = adx[2];
    return true;
}

int DetectSignalStateful() {
    static double last=0; double curr=g_prevConfirmedEmaFast-g_prevConfirmedEmaStandard;
    int sig=0; if(last<=0 && curr>0) sig=1; else if(last>=0 && curr<0) sig=-1;
    if(last!=0 || curr!=0) last=curr;
    return sig;
}

int DetectSignal() {
    double d_now=g_emaFast-g_emaStandard; double d_prev=g_emaFast_prev-g_emaStandard_prev;
    if(d_prev<=0 && d_now>0) return 1; if(d_prev>=0 && d_now<0) return -1; return 0;
}

void ProcessNewBar(int signal, datetime currentBarTime, bool isSecondTimeframe) {
    if(signal != 0) {
        int timeFormat = isSecondTimeframe ? TIME_DATE|TIME_MINUTES|TIME_SECONDS : TIME_DATE|TIME_MINUTES;
        PrintFormat(">>> シグナル: %s | 価格: %.2f | ADX: %.1f", signal==1?"買い":"売り", g_customBars[g_customBarCount-1].close, g_prevConfirmedADX);
        ProcessSignal(signal);
    }
    if(g_ticket > 0) ManagePosition();
    if(InpShowEMALines) DrawEMALines();
    if(InpShowEMAFill) DrawEMAFill();
}

void ProcessSignal(int sig) {
    if(!g_trading_active) return;

    double check_adx = g_useSecondTimeframe ? g_prevConfirmedADX : g_adx;
    double prev_check_adx = g_useSecondTimeframe ? g_prev2ConfirmedADX : g_prevConfirmedADX;

    if(InpUseADXFilter) {
        if(check_adx < InpADX_Threshold) return;
        if(InpADX_RisingOnly) {
            if(check_adx <= prev_check_adx) return;
        }
    }

    if(g_ticket > 0 && g_direction != sig) ClosePosition("[パターンB] 反転決済");
    if(g_direction == sig) return;
    OpenPosition(sig);
}

void OpenPosition(int sig) {
    if(g_ticket > 0) return;
    MqlTick tick;
    if(!SymbolInfoTick(_Symbol, tick)) return;

    double cross_price = (g_emaFast + g_emaStandard) / 2.0;
    g_sl1_price = cross_price;

    if(sig == 1) g_sl2_price = g_sl1_price * (1.0 - InpSL2_Offset_Percent / 100.0);
    else g_sl2_price = g_sl1_price * (1.0 + InpSL2_Offset_Percent / 100.0);

    double entry_price = (sig == 1) ? tick.ask : tick.bid;
    long stops_level = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    double min_dist = stops_level * SymbolInfoDouble(_Symbol, SYMBOL_POINT) + (tick.ask - tick.bid);

    if(MathAbs(entry_price - g_sl2_price) < min_dist) {
        if(sig == 1) g_sl2_price = entry_price - min_dist;
        else g_sl2_price = entry_price + min_dist;
    }
    g_sl2_price = NormalizeDouble(g_sl2_price, g_digits);

    g_f1sl_price = g_sl2_price;
    g_current_sl = g_f1sl_price;
    g_htf_same_direction = true;

    if(sig == 1) {
        g_initial_risk = entry_price - g_f1sl_price;
        g_highest_price = tick.ask;
        g_f3sl_price = g_sl1_price + (g_atr * InpPatF_ATR_Mult);
    } else {
        g_initial_risk = g_f1sl_price - entry_price;
        g_lowest_price = tick.bid;
        g_f3sl_price = g_sl1_price - (g_atr * InpPatF_ATR_Mult);
    }

    g_early_be_set = false; g_breakeven_set = false; g_f2sl_set = false; g_f3sl_set = false;
    g_f2sl_price = 0; g_tp2_price = 0;

    double lotSize = CalculateLotSize();
    bool result = (sig == 1) ? g_trade.Buy(lotSize, _Symbol, 0, g_sl2_price, 0, InpComment)
                             : g_trade.Sell(lotSize, _Symbol, 0, g_sl2_price, 0, InpComment);

    if(result) {
        g_ticket = g_trade.ResultOrder();
        g_direction = sig;
        g_entryTime = TimeCurrent();
        g_entryBarIndex = 0;
        g_entryPrice = g_trade.ResultPrice();
    }
}

void CheckF2SL() {
    if(g_f2sl_set || g_ticket == 0) return;
    MqlTick tick;
    if(!SymbolInfoTick(_Symbol, tick)) return;

    double current_price = (g_direction == 1) ? tick.bid : tick.ask;
    double price_move = MathAbs(current_price - g_entryPrice);
    double currentPosSL = PositionGetDouble(POSITION_SL);
    long stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    double min_dist = stopLevel * _Point;
    double sl_target = 0;

    // Pattern E
    if(InpUsePatE && price_move >= (g_initial_risk * InpPatE_Trigger)) {
        double sl_raise = g_initial_risk / InpPatE_Div_Trend;
        sl_target = (g_direction == 1) ? g_entryPrice + sl_raise : g_entryPrice - sl_raise;
        sl_target = NormalizeDouble(sl_target, g_digits);
        if(MathAbs(current_price - sl_target) >= min_dist && MathAbs(currentPosSL - sl_target) > _Point) {
            if(g_trade.PositionModify(g_ticket, sl_target, 0)) {
                g_f2sl_set = true; g_breakeven_set = true; g_early_be_set = true;
                g_current_sl = sl_target; g_f2sl_price = sl_target;
            }
        } else { g_f2sl_set = true; }
        return;
    }

    // Pattern D
    if(InpUsePatD && !g_breakeven_set && price_move >= (g_initial_risk * InpPatD_Trigger)) {
        double offset_val = g_entryPrice * (InpPatD_Offset / 100.0);
        sl_target = (g_direction == 1) ? (g_entryPrice + offset_val) : (g_entryPrice - offset_val);
        sl_target = NormalizeDouble(sl_target, g_digits);
        if(MathAbs(current_price - sl_target) >= min_dist && MathAbs(currentPosSL - sl_target) > _Point) {
            if(g_trade.PositionModify(g_ticket, sl_target, 0)) {
                g_breakeven_set = true; g_early_be_set = true; g_current_sl = sl_target;
            }
        } else { g_breakeven_set = true; }
        return;
    }

    // Pattern C
    if(InpUsePatC && !g_early_be_set && price_move >= (g_initial_risk * InpPatC_Trigger)) {
        double offset_val = g_entryPrice * (InpPatC_Offset / 100.0);
        sl_target = (g_direction == 1) ? (g_entryPrice + offset_val) : (g_entryPrice - offset_val);
        sl_target = NormalizeDouble(sl_target, g_digits);
        if(MathAbs(current_price - sl_target) >= min_dist && MathAbs(currentPosSL - sl_target) > _Point) {
            if(g_trade.PositionModify(g_ticket, sl_target, 0)) {
                g_early_be_set = true; g_current_sl = sl_target;
            }
        } else { g_early_be_set = true; }
    }
}

void ManagePosition() {
    if(!InpUsePatF) return;
    if(!PositionSelectByTicket(g_ticket)) { CheckClosed(); return; }
    g_entryBarIndex++;
    if(g_f3sl_set) return;

    MqlTick tick;
    if(!SymbolInfoTick(_Symbol, tick)) return;

    if(g_entryBarIndex >= InpPatF_Bars) {
        double current_price = (g_direction == 1) ? tick.bid : tick.ask;
        bool f3sl_met = (g_direction == 1) ? (current_price >= g_f3sl_price) : (current_price <= g_f3sl_price);
        if(f3sl_met) {
            double final_sl = g_f3sl_price;
            if(g_f2sl_set) {
                final_sl = (g_direction == 1) ? MathMax(g_f2sl_price, g_f3sl_price) : MathMin(g_f2sl_price, g_f3sl_price);
            }
            final_sl = NormalizeDouble(final_sl, g_digits);

            long stops_level = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
            if(MathAbs(current_price - final_sl) >= stops_level * _Point && MathAbs(PositionGetDouble(POSITION_SL) - final_sl) > _Point) {
                if(g_trade.PositionModify(g_ticket, final_sl, 0)) {
                    g_f3sl_set = true; g_current_sl = final_sl;
                }
            } else { g_f3sl_set = true; }
        }
    }
}

void CheckTP2Exit() {
    if(!InpUsePatG) return;
    if(!g_f3sl_set || g_ticket == 0) return;
    MqlTick tick;
    if(!SymbolInfoTick(_Symbol, tick)) return;

    if(g_direction == 1) {
        if(tick.bid > g_highest_price) g_highest_price = tick.bid;
        g_tp2_price = g_sl1_price + (g_highest_price - g_sl1_price) * (InpPatG_Ratio / 100.0);
        if(tick.bid <= g_tp2_price) ClosePosition("[パターンG] トレンド極値決済");
    } else {
        if(tick.ask < g_lowest_price) g_lowest_price = tick.ask;
        g_tp2_price = g_sl1_price - (g_sl1_price - g_lowest_price) * (InpPatG_Ratio / 100.0);
        if(tick.ask >= g_tp2_price) ClosePosition("[パターンG] トレンド極値決済");
    }
}

void ClosePosition(string reason) {
    if(g_ticket == 0) return;
    if(!PositionSelectByTicket(g_ticket)) { CheckClosed(); return; }
    double pnl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
    if(g_trade.PositionClose(g_ticket)) {
        PrintFormat("決済完了: %s | 損益: $%.2f", reason, pnl);
        UpdateStats(pnl); ResetGlobals();
    }
}

void CheckClosed() {
    if(g_ticket == 0) return;
    if(HistorySelectByPosition(g_ticket)) {
        ulong ticket = 0;
        for(int i=HistoryDealsTotal()-1; i>=0; i--) {
            if(HistoryDealGetInteger(HistoryDealGetTicket(i), DEAL_ENTRY)==DEAL_ENTRY_OUT) { ticket=HistoryDealGetTicket(i); break; }
        }
        double pnl = HistoryDealGetDouble(ticket, DEAL_PROFIT);
        UpdateStats(pnl); ResetGlobals();
    }
}

void ResetGlobals() {
    g_ticket = 0; g_direction = 0;
    g_early_be_set = false; g_breakeven_set = false;
    g_f2sl_set = false; g_f3sl_set = false;
}

void UpdateStats(double p) {
    g_totalTrades++;
    if(p > 0) { g_wins++; g_consecutive_losses = 0; }
    else { g_consecutive_losses++; CheckConsecutiveLosses(); }
    g_profit += p;
}

void CheckConsecutiveLosses() {
    if(g_consecutive_losses >= InpMaxConsecutiveLosses) {
        g_trading_active = false;
        g_trading_stopped_at = TimeCurrent();
        Print("停止: 最大連敗数に到達しました");
    }
}

void CheckTradingResume() {
    if(!g_trading_active && TimeCurrent() - g_trading_stopped_at >= InpCoolingPeriodMinutes * 60) {
        g_trading_active = true;
        g_consecutive_losses = 0;
        Print("再開: 冷却期間が終了しました");
    }
}

double CalculateLotSize() {
    double lot = InpFixedLots;
    if(InpLotMode == LOT_MARGIN_LEVEL) {
        double equity = AccountInfoDouble(ACCOUNT_EQUITY);
        double margin = 0;
        if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, 1.0, SymbolInfoDouble(_Symbol, SYMBOL_ASK), margin))
            margin = SymbolInfoDouble(_Symbol, SYMBOL_MARGIN_INITIAL);

        if(margin > 0) {
            lot = (equity / (InpTargetMarginLevel / 100.0)) / margin * 0.9;
            lot = MathMax(lot, InpMinLots);
            lot = MathMin(lot, InpMaxLots);
            double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
            lot = MathFloor(lot / step) * step;
        }
    }
    return lot;
}

double CalculateATR(int p, int i) {
    if(i < p) return 0;
    double sum = 0;
    for(int k = i - p + 1; k <= i; k++) {
        double tr = g_customBars[k].high - g_customBars[k].low;
        if(k > 0) {
            tr = MathMax(tr, MathMax(MathAbs(g_customBars[k].high - g_customBars[k-1].close), MathAbs(g_customBars[k].low - g_customBars[k-1].close)));
        }
        sum += tr;
    }
    return sum / p;
}

CUSTOM_TIMEFRAME GetHigherTimeframe(CUSTOM_TIMEFRAME tf) {
    int s = (int)tf * 4;
    return (s <= 60) ? TF_M1 : TF_M5;
}

ENUM_TIMEFRAMES CustomToMT5Timeframe(CUSTOM_TIMEFRAME tf) {
    return (tf == TF_M5) ? PERIOD_M5 : PERIOD_M1;
}

void DrawEMALines() { ChartRedraw(); }
void DeleteEMALines() { ObjectsDeleteAll(0, g_emaLinePrefix); }
void DrawEMAFill() {}
void DeleteEMAFill() { ObjectsDeleteAll(0, g_emaFillPrefix); }

void UpdateInfoPanel() {
    string t = "== Golden Sniper v13.2 TimeFilter Fix ==\n";
    MqlTick tick; SymbolInfoTick(_Symbol, tick);
    double spread = (tick.ask - tick.bid) / _Point / 10.0;

    double adx_val = g_useSecondTimeframe ? g_prevConfirmedADX : g_adx;
    string slope = (adx_val > (g_useSecondTimeframe ? g_prev2ConfirmedADX : g_prevConfirmedADX)) ? "↑(OK)" : "↓(SKIP)";
    string timeStatus = IsTradingTime() ? "稼働中" : "時間外";

    t += StringFormat("Time: %02d:00-%02d:00 (%s)\n", InpStartHour, InpEndHour, timeStatus);
    t += StringFormat("Spread: %.1f / ADX: %.1f %s\n", spread, adx_val, slope);
    t += StringFormat("EMA: %d-%d / PatG: %.1f%%\n", InpEMA_Fast, InpEMA_Standard, InpPatG_Ratio);
    t += StringFormat("本日: %d戦%d勝 / 損益: $%.0f", g_totalTrades, g_wins, g_profit);

    string objName = g_panelPrefix + "Status";
    if(ObjectFind(0, objName) < 0) {
        ObjectCreate(0, objName, OBJ_LABEL, 0, 0, 0);
        ObjectSetInteger(0, objName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
        ObjectSetInteger(0, objName, OBJPROP_FONTSIZE, 10);
    }
    ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, 20);
    ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, 20);
    ObjectSetString(0, objName, OBJPROP_TEXT, t);
    ObjectSetInteger(0, objName, OBJPROP_COLOR, clrWhite);
}

void DeleteInfoPanel() { ObjectsDeleteAll(0, g_panelPrefix); }
//+------------------------------------------------------------------+
