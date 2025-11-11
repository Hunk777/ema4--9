//+------------------------------------------------------------------+
//|                                                           e3.mq5 |
//|                              EMAクロス戦略 - リアルタイム版       |
//+------------------------------------------------------------------+
#property copyright "2024"
#property version   "3.00"
#property description "EMAクロス即座エントリー/エグジット"

#include <Trade\Trade.mqh>
CTrade trade;

//--- パラメータ
input group "===== 時間軸 ====="
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M1;  // 時間軸

input group "===== EMA ====="
input int InpFastEMA = 3;                         // 短期EMA
input int InpSlowEMA = 13;                        // 長期EMA

input group "===== ポジション ====="
input double InpLots = 0.01;                      // ロット数

input group "===== EMAライン ====="
input bool InpShowLines = true;                   // ライン表示
input int InpMaxBars = 500;                       // 表示バー数

input group "===== 情報板 ====="
input bool InpShowPanel = true;                   // パネル表示

input group "===== その他 ====="
input int InpMagic = 10003;                       // マジックナンバー

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
int g_tickCount = 0;

//+------------------------------------------------------------------+
//| 初期化                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
    Print("=== e3 Starting ===");

    // 古いオブジェクトを完全削除
    ObjectsDeleteAll(0, -1, -1);

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
    Print("Lots: ", InpLots);
    Print("=== e3 Ready ===");

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| 終了処理                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    Print("=== e3 Stopped ===");

    if(g_fastHandle != INVALID_HANDLE) IndicatorRelease(g_fastHandle);
    if(g_slowHandle != INVALID_HANDLE) IndicatorRelease(g_slowHandle);

    // オブジェクト完全削除
    ObjectsDeleteAll(0, "E3_");
}

//+------------------------------------------------------------------+
//| ティック処理                                                     |
//+------------------------------------------------------------------+
void OnTick()
{
    g_tickCount++;

    // EMAデータ取得（毎ティック）
    if(CopyBuffer(g_fastHandle, 0, 0, 3, g_fastBuffer) <= 0) return;
    if(CopyBuffer(g_slowHandle, 0, 0, 3, g_slowBuffer) <= 0) return;

    g_fastPrev = g_fastNow;
    g_slowPrev = g_slowNow;

    g_fastNow = g_fastBuffer[0];
    g_slowNow = g_slowBuffer[0];

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
        Print(">>> SIGNAL: ", signal == 1 ? "BUY" : "SELL", " | Fast: ", g_fastNow, " | Slow: ", g_slowNow);

        // 既存ポジションがあれば決済
        if(g_position != 0)
        {
            ClosePosition();
        }

        // 新規エントリー（即座に）
        OpenPosition(signal);
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
void OpenPosition(int signal)
{
    bool result = false;

    if(signal == 1)
    {
        result = trade.Buy(InpLots, _Symbol, 0, 0, 0, "e3");
    }
    else if(signal == -1)
    {
        result = trade.Sell(InpLots, _Symbol, 0, 0, 0, "e3");
    }

    if(result)
    {
        g_ticket = trade.ResultOrder();
        g_position = signal;
        Print(">>> OPENED: ", signal == 1 ? "BUY" : "SELL", " | Ticket: ", g_ticket);
    }
    else
    {
        Print(">>> OPEN FAILED: ", trade.ResultRetcode());
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
        Print(">>> CLOSED: Ticket ", g_ticket);
        g_ticket = 0;
        g_position = 0;
    }
}

//+------------------------------------------------------------------+
//| パネル作成                                                       |
//+------------------------------------------------------------------+
void CreatePanel()
{
    ObjectCreate(0, "E3_Panel_BG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
    ObjectSetInteger(0, "E3_Panel_BG", OBJPROP_CORNER, CORNER_LEFT_UPPER);
    ObjectSetInteger(0, "E3_Panel_BG", OBJPROP_XDISTANCE, 10);
    ObjectSetInteger(0, "E3_Panel_BG", OBJPROP_YDISTANCE, 30);
    ObjectSetInteger(0, "E3_Panel_BG", OBJPROP_XSIZE, 250);
    ObjectSetInteger(0, "E3_Panel_BG", OBJPROP_YSIZE, 120);
    ObjectSetInteger(0, "E3_Panel_BG", OBJPROP_BGCOLOR, C'20,20,30');
    ObjectSetInteger(0, "E3_Panel_BG", OBJPROP_BORDER_TYPE, BORDER_FLAT);
    ObjectSetInteger(0, "E3_Panel_BG", OBJPROP_COLOR, clrDodgerBlue);
    ObjectSetInteger(0, "E3_Panel_BG", OBJPROP_WIDTH, 2);
}

//+------------------------------------------------------------------+
//| パネル更新                                                       |
//+------------------------------------------------------------------+
void UpdatePanel()
{
    string lines[7];
    color colors[7];

    MqlTick tick;
    SymbolInfoTick(_Symbol, tick);

    int idx = 0;

    // タイトル
    lines[idx] = "═══ e3 (EMA) ═══";
    colors[idx++] = clrDodgerBlue;

    // 価格
    lines[idx] = StringFormat("Price: %.2f", tick.bid);
    colors[idx++] = clrWhite;

    // 区切り
    lines[idx] = "───────────";
    colors[idx++] = clrGray;

    // EMA値
    lines[idx] = StringFormat("Fast(%d): %.2f", InpFastEMA, g_fastNow);
    colors[idx++] = clrAqua;

    lines[idx] = StringFormat("Slow(%d): %.2f", InpSlowEMA, g_slowNow);
    colors[idx++] = clrMagenta;

    // 区切り
    lines[idx] = "───────────";
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

    // ラベル作成/更新
    for(int i = 0; i < ArraySize(lines); i++)
    {
        string objName = "E3_Panel_L" + IntegerToString(i);

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
    // 既存ライン削除（E3専用プレフィックス）
    ObjectsDeleteAll(0, "E3_Fast_");
    ObjectsDeleteAll(0, "E3_Slow_");

    int bars = MathMin(InpMaxBars, Bars(_Symbol, InpTimeframe));

    double fastArr[], slowArr[];
    ArraySetAsSeries(fastArr, true);
    ArraySetAsSeries(slowArr, true);

    if(CopyBuffer(g_fastHandle, 0, 0, bars + 1, fastArr) <= 0) return;
    if(CopyBuffer(g_slowHandle, 0, 0, bars + 1, slowArr) <= 0) return;

    // Fast EMA（水色）
    for(int i = 0; i < bars; i++)
    {
        datetime t1 = iTime(_Symbol, InpTimeframe, i);
        datetime t2 = iTime(_Symbol, InpTimeframe, i + 1);

        string name = "E3_Fast_" + IntegerToString(i);
        ObjectCreate(0, name, OBJ_TREND, 0, t1, fastArr[i], t2, fastArr[i + 1]);
        ObjectSetInteger(0, name, OBJPROP_COLOR, clrAqua);
        ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
        ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
        ObjectSetInteger(0, name, OBJPROP_BACK, true);
        ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
    }

    // Slow EMA（マゼンタ）
    for(int i = 0; i < bars; i++)
    {
        datetime t1 = iTime(_Symbol, InpTimeframe, i);
        datetime t2 = iTime(_Symbol, InpTimeframe, i + 1);

        string name = "E3_Slow_" + IntegerToString(i);
        ObjectCreate(0, name, OBJ_TREND, 0, t1, slowArr[i], t2, slowArr[i + 1]);
        ObjectSetInteger(0, name, OBJPROP_COLOR, clrMagenta);
        ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
        ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
        ObjectSetInteger(0, name, OBJPROP_BACK, true);
        ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
    }
}
//+------------------------------------------------------------------+
