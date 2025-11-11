//+------------------------------------------------------------------+
//|                                                           e5.mq5 |
//|                       EMAクロス戦略 + ADX + 矢印 + 領域塗りつぶし |
//+------------------------------------------------------------------+
#property copyright "2024"
#property version   "5.00"
#property description "EMAクロス + ADX + エントリー矢印 + 領域塗りつぶし"

#include <Trade\Trade.mqh>
CTrade trade;

//--- パラメータ
input group "===== 時間軸 ====="
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M1;  // 時間軸

input group "===== EMA ====="
input int InpFastEMA = 3;                         // 短期EMA
input int InpSlowEMA = 13;                        // 長期EMA

input group "===== ADX ====="
input int InpADXPeriod = 14;                      // ADX期間

input group "===== ポジション ====="
input double InpLots = 0.01;                      // ロット数

input group "===== EMAライン ====="
input bool InpShowLines = true;                   // ライン表示
input bool InpShowFill = true;                    // 領域塗りつぶし
input int InpMaxBars = 500;                       // 表示バー数

input group "===== 情報板 ====="
input bool InpShowPanel = true;                   // パネル表示

input group "===== その他 ====="
input int InpMagic = 10005;                       // マジックナンバー

//--- グローバル変数
int g_fastHandle = INVALID_HANDLE;
int g_slowHandle = INVALID_HANDLE;
int g_adxHandle = INVALID_HANDLE;

double g_fastBuffer[];
double g_slowBuffer[];
double g_adxBuffer[];

double g_fastNow = 0, g_slowNow = 0;
double g_fastPrev = 0, g_slowPrev = 0;
double g_adxNow = 0;

ulong g_ticket = 0;
int g_position = 0;  // 0=なし, 1=買い, -1=売り

datetime g_lastBarTime = 0;
int g_tickCount = 0;
int g_tradeCount = 0;

//+------------------------------------------------------------------+
//| 初期化                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
    Print("=== e5 Starting ===");

    // 古いオブジェクトを完全削除
    ObjectsDeleteAll(0, -1, -1);

    // EMAハンドル作成
    g_fastHandle = iMA(_Symbol, InpTimeframe, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
    g_slowHandle = iMA(_Symbol, InpTimeframe, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
    g_adxHandle = iADX(_Symbol, InpTimeframe, InpADXPeriod);

    if(g_fastHandle == INVALID_HANDLE || g_slowHandle == INVALID_HANDLE || g_adxHandle == INVALID_HANDLE)
    {
        Print("Error: Indicator failed");
        return INIT_FAILED;
    }

    ArraySetAsSeries(g_fastBuffer, true);
    ArraySetAsSeries(g_slowBuffer, true);
    ArraySetAsSeries(g_adxBuffer, true);

    trade.SetExpertMagicNumber(InpMagic);

    // パネル作成
    if(InpShowPanel)
    {
        CreatePanel();
    }

    // EMAライン描画
    if(InpShowLines)
    {
        Sleep(1000);
        DrawEMALines();
    }

    Print("EMA: ", InpFastEMA, "/", InpSlowEMA);
    Print("ADX Period: ", InpADXPeriod);
    Print("Lots: ", InpLots);
    Print("=== e5 Ready ===");

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| 終了処理                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    Print("=== e5 Stopped ===");

    if(g_fastHandle != INVALID_HANDLE) IndicatorRelease(g_fastHandle);
    if(g_slowHandle != INVALID_HANDLE) IndicatorRelease(g_slowHandle);
    if(g_adxHandle != INVALID_HANDLE) IndicatorRelease(g_adxHandle);

    // オブジェクト完全削除
    ObjectsDeleteAll(0, "E5_");
}

//+------------------------------------------------------------------+
//| ティック処理                                                     |
//+------------------------------------------------------------------+
void OnTick()
{
    g_tickCount++;

    // インジケーターデータ取得（毎ティック）
    if(CopyBuffer(g_fastHandle, 0, 0, 3, g_fastBuffer) <= 0) return;
    if(CopyBuffer(g_slowHandle, 0, 0, 3, g_slowBuffer) <= 0) return;
    if(CopyBuffer(g_adxHandle, 0, 0, 1, g_adxBuffer) <= 0) return;

    g_fastPrev = g_fastNow;
    g_slowPrev = g_slowNow;

    g_fastNow = g_fastBuffer[0];
    g_slowNow = g_slowBuffer[0];
    g_adxNow = g_adxBuffer[0];

    // 初回スキップ
    if(g_fastPrev == 0 || g_slowPrev == 0)
    {
        g_fastPrev = g_fastNow;
        g_slowPrev = g_slowNow;
        return;
    }

    // シグナル検出（毎ティック）
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

    // シグナル処理（即座にエントリー/エグジット）
    if(signal != 0)
    {
        MqlTick tick;
        SymbolInfoTick(_Symbol, tick);
        double price = (signal == 1) ? tick.ask : tick.bid;

        Print(">>> SIGNAL: ", signal == 1 ? "BUY" : "SELL", " | Fast: ", g_fastNow, " | Slow: ", g_slowNow, " | ADX: ", g_adxNow);

        // 既存ポジションがあれば決済
        if(g_position != 0)
        {
            ClosePosition(price);
        }

        // 新規エントリー（即座に）
        OpenPosition(signal, price);
    }

    // パネル更新（30ティックごと）
    if(InpShowPanel && g_tickCount % 30 == 0)
    {
        UpdatePanel();
    }

    // 新バーチェック（EMAライン更新用）
    datetime currentBar = iTime(_Symbol, InpTimeframe, 0);
    if(currentBar != g_lastBarTime)
    {
        g_lastBarTime = currentBar;

        if(InpShowLines)
        {
            DrawEMALines();
        }
    }
}

//+------------------------------------------------------------------+
//| ポジションオープン                                               |
//+------------------------------------------------------------------+
void OpenPosition(int signal, double price)
{
    bool result = false;

    if(signal == 1)
    {
        result = trade.Buy(InpLots, _Symbol, 0, 0, 0, "e5");
    }
    else if(signal == -1)
    {
        result = trade.Sell(InpLots, _Symbol, 0, 0, 0, "e5");
    }

    if(result)
    {
        g_ticket = trade.ResultOrder();
        g_position = signal;
        g_tradeCount++;

        Print(">>> OPENED: ", signal == 1 ? "BUY" : "SELL", " | Ticket: ", g_ticket, " | Price: ", price);

        // エントリー矢印を描画
        DrawEntryArrow(signal, price);
    }
    else
    {
        Print(">>> OPEN FAILED: ", trade.ResultRetcode());
    }
}

//+------------------------------------------------------------------+
//| ポジションクローズ                                               |
//+------------------------------------------------------------------+
void ClosePosition(double price)
{
    if(g_ticket == 0) return;

    int closedPosition = g_position;

    if(trade.PositionClose(g_ticket))
    {
        Print(">>> CLOSED: Ticket ", g_ticket, " | Price: ", price);

        // エグジット矢印を描画
        DrawExitArrow(closedPosition, price);

        g_ticket = 0;
        g_position = 0;
    }
}

//+------------------------------------------------------------------+
//| エントリー矢印描画                                               |
//+------------------------------------------------------------------+
void DrawEntryArrow(int signal, double price)
{
    datetime time = TimeCurrent();
    string name = "E5_Entry_" + IntegerToString(g_tradeCount);

    if(signal == 1)
    {
        // 買いエントリー（上向き矢印）
        ObjectCreate(0, name, OBJ_ARROW_BUY, 0, time, price);
        ObjectSetInteger(0, name, OBJPROP_COLOR, clrLime);
        ObjectSetInteger(0, name, OBJPROP_WIDTH, 3);
    }
    else
    {
        // 売りエントリー（下向き矢印）
        ObjectCreate(0, name, OBJ_ARROW_SELL, 0, time, price);
        ObjectSetInteger(0, name, OBJPROP_COLOR, clrRed);
        ObjectSetInteger(0, name, OBJPROP_WIDTH, 3);
    }

    ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

//+------------------------------------------------------------------+
//| エグジット矢印描画                                               |
//+------------------------------------------------------------------+
void DrawExitArrow(int closedPosition, double price)
{
    datetime time = TimeCurrent();
    string name = "E5_Exit_" + IntegerToString(g_tradeCount);

    if(closedPosition == 1)
    {
        // 買いポジション決済（下向き矢印・小さめ）
        ObjectCreate(0, name, OBJ_ARROW_DOWN, 0, time, price);
        ObjectSetInteger(0, name, OBJPROP_COLOR, clrYellow);
        ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
    }
    else
    {
        // 売りポジション決済（上向き矢印・小さめ）
        ObjectCreate(0, name, OBJ_ARROW_UP, 0, time, price);
        ObjectSetInteger(0, name, OBJPROP_COLOR, clrYellow);
        ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
    }

    ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

//+------------------------------------------------------------------+
//| パネル作成                                                       |
//+------------------------------------------------------------------+
void CreatePanel()
{
    ObjectCreate(0, "E5_Panel_BG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
    ObjectSetInteger(0, "E5_Panel_BG", OBJPROP_CORNER, CORNER_LEFT_UPPER);
    ObjectSetInteger(0, "E5_Panel_BG", OBJPROP_XDISTANCE, 10);
    ObjectSetInteger(0, "E5_Panel_BG", OBJPROP_YDISTANCE, 30);
    ObjectSetInteger(0, "E5_Panel_BG", OBJPROP_XSIZE, 280);
    ObjectSetInteger(0, "E5_Panel_BG", OBJPROP_YSIZE, 150);
    ObjectSetInteger(0, "E5_Panel_BG", OBJPROP_BGCOLOR, C'20,20,30');
    ObjectSetInteger(0, "E5_Panel_BG", OBJPROP_BORDER_TYPE, BORDER_FLAT);
    ObjectSetInteger(0, "E5_Panel_BG", OBJPROP_COLOR, clrDodgerBlue);
    ObjectSetInteger(0, "E5_Panel_BG", OBJPROP_WIDTH, 2);
}

//+------------------------------------------------------------------+
//| パネル更新                                                       |
//+------------------------------------------------------------------+
void UpdatePanel()
{
    string lines[9];
    color colors[9];

    MqlTick tick;
    SymbolInfoTick(_Symbol, tick);

    int idx = 0;

    // タイトル
    lines[idx] = "═══ e5 (EMA+ADX) ═══";
    colors[idx++] = clrDodgerBlue;

    // 価格
    lines[idx] = StringFormat("Price: %.2f", tick.bid);
    colors[idx++] = clrWhite;

    // 区切り
    lines[idx] = "─────────────";
    colors[idx++] = clrGray;

    // EMA値
    lines[idx] = StringFormat("Fast(%d): %.2f", InpFastEMA, g_fastNow);
    colors[idx++] = clrAqua;

    lines[idx] = StringFormat("Slow(%d): %.2f", InpSlowEMA, g_slowNow);
    colors[idx++] = clrMagenta;

    // ADX値
    lines[idx] = StringFormat("ADX(%d): %.2f", InpADXPeriod, g_adxNow);
    colors[idx++] = clrYellow;

    // 区切り
    lines[idx] = "─────────────";
    colors[idx++] = clrGray;

    // ポジション
    string posText = "NONE";
    color posColor = clrGray;

    if(g_position == 1)
    {
        posText = "LONG";
        posColor = clrLime;
    }
    else if(g_position == -1)
    {
        posText = "SHORT";
        posColor = clrRed;
    }

    lines[idx] = StringFormat("Position: %s", posText);
    colors[idx++] = posColor;

    // 取引回数
    lines[idx] = StringFormat("Trades: %d", g_tradeCount);
    colors[idx++] = clrWhite;

    // ラベル作成/更新
    for(int i = 0; i < ArraySize(lines); i++)
    {
        string objName = "E5_Panel_L" + IntegerToString(i);

        if(ObjectFind(0, objName) < 0)
        {
            ObjectCreate(0, objName, OBJ_LABEL, 0, 0, 0);
            ObjectSetInteger(0, objName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
            ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, 20);
            ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, 40 + i * 16);
            ObjectSetString(0, objName, OBJPROP_FONT, "Consolas");
            ObjectSetInteger(0, objName, OBJPROP_FONTSIZE, 9);
        }

        ObjectSetString(0, objName, OBJPROP_TEXT, lines[i]);
        ObjectSetInteger(0, objName, OBJPROP_COLOR, colors[i]);
    }
}

//+------------------------------------------------------------------+
//| EMAライン描画                                                    |
//+------------------------------------------------------------------+
void DrawEMALines()
{
    // 既存ライン削除
    ObjectsDeleteAll(0, "E5_Fast_");
    ObjectsDeleteAll(0, "E5_Slow_");
    ObjectsDeleteAll(0, "E5_Fill_");

    int bars = MathMin(InpMaxBars, Bars(_Symbol, InpTimeframe));

    double fastArr[], slowArr[];
    ArraySetAsSeries(fastArr, true);
    ArraySetAsSeries(slowArr, true);

    if(CopyBuffer(g_fastHandle, 0, 0, bars + 1, fastArr) <= 0) return;
    if(CopyBuffer(g_slowHandle, 0, 0, bars + 1, slowArr) <= 0) return;

    // 領域塗りつぶし（先に描画して背景にする）
    if(InpShowFill)
    {
        for(int i = 0; i < bars; i++)
        {
            datetime t1 = iTime(_Symbol, InpTimeframe, i);
            datetime t2 = iTime(_Symbol, InpTimeframe, i + 1);

            double fast1 = fastArr[i];
            double fast2 = fastArr[i + 1];
            double slow1 = slowArr[i];
            double slow2 = slowArr[i + 1];

            // ゴールデンクロス状態（Fast > Slow）→ 青
            // デッドクロス状態（Fast < Slow）→ 赤
            color fillColor = (fast1 > slow1) ? C'0,50,150' : C'150,0,0';  // 半透明風

            // 矩形で領域を描画
            string name = "E5_Fill_" + IntegerToString(i);

            // 4点の座標を使って矩形を作成
            double top = MathMax(fast1, slow1);
            double bottom = MathMin(fast1, slow1);

            ObjectCreate(0, name, OBJ_RECTANGLE, 0, t2, top, t1, bottom);
            ObjectSetInteger(0, name, OBJPROP_COLOR, fillColor);
            ObjectSetInteger(0, name, OBJPROP_FILL, true);
            ObjectSetInteger(0, name, OBJPROP_BACK, true);
            ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
        }
    }

    // Fast EMA（水色）- ラインは領域の上に描画
    for(int i = 0; i < bars; i++)
    {
        datetime t1 = iTime(_Symbol, InpTimeframe, i);
        datetime t2 = iTime(_Symbol, InpTimeframe, i + 1);

        string name = "E5_Fast_" + IntegerToString(i);
        ObjectCreate(0, name, OBJ_TREND, 0, t1, fastArr[i], t2, fastArr[i + 1]);
        ObjectSetInteger(0, name, OBJPROP_COLOR, clrAqua);
        ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
        ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
        ObjectSetInteger(0, name, OBJPROP_BACK, false);  // 前面に表示
        ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
    }

    // Slow EMA（マゼンタ）
    for(int i = 0; i < bars; i++)
    {
        datetime t1 = iTime(_Symbol, InpTimeframe, i);
        datetime t2 = iTime(_Symbol, InpTimeframe, i + 1);

        string name = "E5_Slow_" + IntegerToString(i);
        ObjectCreate(0, name, OBJ_TREND, 0, t1, slowArr[i], t2, slowArr[i + 1]);
        ObjectSetInteger(0, name, OBJPROP_COLOR, clrMagenta);
        ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
        ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
        ObjectSetInteger(0, name, OBJPROP_BACK, false);  // 前面に表示
        ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
    }
}
//+------------------------------------------------------------------+
