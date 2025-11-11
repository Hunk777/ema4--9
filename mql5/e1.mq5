//+------------------------------------------------------------------+
//|                                                           e1.mq5 |
//|                                        純粋EMAクロス戦略 v1      |
//+------------------------------------------------------------------+
#property copyright "2024"
#property version   "1.00"
#property description "2本EMA純粋クロス戦略"

#include <Trade\Trade.mqh>
CTrade trade;

//--- パラメータ
input group "===== 時間軸 ====="
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M1;  // 時間軸

input group "===== EMA ====="
input int InpFastEMA = 5;                         // 短期EMA
input int InpSlowEMA = 13;                        // 長期EMA

input group "===== ポジション ====="
input double InpLots = 0.01;                      // ロット数

input group "===== EMAライン ====="
input bool InpShowLines = true;                   // ライン表示
input int InpMaxBars = 500;                       // 表示バー数

input group "===== その他 ====="
input int InpMagic = 10001;                       // マジックナンバー

//--- グローバル変数
int g_fastHandle = INVALID_HANDLE;
int g_slowHandle = INVALID_HANDLE;

double g_fastBuffer[];
double g_slowBuffer[];

double g_fastNow = 0, g_slowNow = 0;
double g_fastPrev = 0, g_slowPrev = 0;

ulong g_ticket = 0;
int g_position = 0;  // 0=なし, 1=買い, -1=売り

datetime g_lastBarTime = 0;

//+------------------------------------------------------------------+
//| 初期化                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
    Print("=== e1 Starting ===");

    // EMAハンドル作成
    g_fastHandle = iMA(_Symbol, InpTimeframe, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
    g_slowHandle = iMA(_Symbol, InpTimeframe, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);

    if(g_fastHandle == INVALID_HANDLE || g_slowHandle == INVALID_HANDLE)
    {
        Print("Error: EMA indicator failed");
        return INIT_FAILED;
    }

    ArraySetAsSeries(g_fastBuffer, true);
    ArraySetAsSeries(g_slowBuffer, true);

    trade.SetExpertMagicNumber(InpMagic);

    // EMAライン描画
    if(InpShowLines)
    {
        Sleep(1000);
        DrawEMALines();
    }

    Print("EMA: ", InpFastEMA, "/", InpSlowEMA);
    Print("Lots: ", InpLots);
    Print("=== e1 Ready ===");

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| 終了処理                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    Print("=== e1 Stopped ===");

    if(g_fastHandle != INVALID_HANDLE) IndicatorRelease(g_fastHandle);
    if(g_slowHandle != INVALID_HANDLE) IndicatorRelease(g_slowHandle);

    // オブジェクト削除
    ObjectsDeleteAll(0, "EMA_");
}

//+------------------------------------------------------------------+
//| ティック処理                                                     |
//+------------------------------------------------------------------+
void OnTick()
{
    datetime currentBar = iTime(_Symbol, InpTimeframe, 0);

    // 新しいバーチェック
    if(currentBar == g_lastBarTime) return;

    g_lastBarTime = currentBar;

    // EMAデータ取得
    if(CopyBuffer(g_fastHandle, 0, 0, 3, g_fastBuffer) <= 0) return;
    if(CopyBuffer(g_slowHandle, 0, 0, 3, g_slowBuffer) <= 0) return;

    g_fastPrev = g_fastNow;
    g_slowPrev = g_slowNow;

    g_fastNow = g_fastBuffer[0];
    g_slowNow = g_slowBuffer[0];

    // シグナル検出
    int signal = 0;

    // ゴールデンクロス
    if(g_fastPrev <= g_slowPrev && g_fastNow > g_slowNow)
    {
        signal = 1;  // 買い
    }
    // デッドクロス
    else if(g_fastPrev >= g_slowPrev && g_fastNow < g_slowNow)
    {
        signal = -1;  // 売り
    }

    // シグナル処理
    if(signal != 0)
    {
        Print(">>> Signal: ", signal == 1 ? "BUY" : "SELL");

        // 反対ポジションがあれば決済
        if(g_position != 0 && g_position != signal)
        {
            ClosePosition();
        }

        // 新規エントリー
        if(g_position == 0)
        {
            OpenPosition(signal);
        }
    }

    // EMAライン更新
    if(InpShowLines)
    {
        DrawEMALines();
    }
}

//+------------------------------------------------------------------+
//| ポジションオープン                                               |
//+------------------------------------------------------------------+
void OpenPosition(int signal)
{
    bool result = false;

    if(signal == 1)
    {
        result = trade.Buy(InpLots, _Symbol, 0, 0, 0, "e1_BUY");
    }
    else if(signal == -1)
    {
        result = trade.Sell(InpLots, _Symbol, 0, 0, 0, "e1_SELL");
    }

    if(result)
    {
        g_ticket = trade.ResultOrder();
        g_position = signal;
        Print("Opened: ", signal == 1 ? "BUY" : "SELL", " | Ticket: ", g_ticket);
    }
    else
    {
        Print("Open Failed: ", trade.ResultRetcode());
    }
}

//+------------------------------------------------------------------+
//| ポジションクローズ                                               |
//+------------------------------------------------------------------+
void ClosePosition()
{
    if(g_ticket == 0) return;

    if(trade.PositionClose(g_ticket))
    {
        Print("Closed: Ticket ", g_ticket);
        g_ticket = 0;
        g_position = 0;
    }
}

//+------------------------------------------------------------------+
//| EMAライン描画                                                    |
//+------------------------------------------------------------------+
void DrawEMALines()
{
    // 既存ライン削除
    ObjectsDeleteAll(0, "EMA_");

    int bars = MathMin(InpMaxBars, Bars(_Symbol, InpTimeframe));

    double fastArr[], slowArr[];
    ArraySetAsSeries(fastArr, true);
    ArraySetAsSeries(slowArr, true);

    if(CopyBuffer(g_fastHandle, 0, 0, bars + 1, fastArr) <= 0) return;
    if(CopyBuffer(g_slowHandle, 0, 0, bars + 1, slowArr) <= 0) return;

    // Fast EMA
    for(int i = 0; i < bars; i++)
    {
        datetime t1 = iTime(_Symbol, InpTimeframe, i);
        datetime t2 = iTime(_Symbol, InpTimeframe, i + 1);

        string name = "EMA_Fast_" + IntegerToString(i);
        ObjectCreate(0, name, OBJ_TREND, 0, t1, fastArr[i], t2, fastArr[i + 1]);
        ObjectSetInteger(0, name, OBJPROP_COLOR, clrAqua);
        ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
        ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
        ObjectSetInteger(0, name, OBJPROP_BACK, true);
    }

    // Slow EMA
    for(int i = 0; i < bars; i++)
    {
        datetime t1 = iTime(_Symbol, InpTimeframe, i);
        datetime t2 = iTime(_Symbol, InpTimeframe, i + 1);

        string name = "EMA_Slow_" + IntegerToString(i);
        ObjectCreate(0, name, OBJ_TREND, 0, t1, slowArr[i], t2, slowArr[i + 1]);
        ObjectSetInteger(0, name, OBJPROP_COLOR, clrMagenta);
        ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
        ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
        ObjectSetInteger(0, name, OBJPROP_BACK, true);
    }
}
//+------------------------------------------------------------------+
