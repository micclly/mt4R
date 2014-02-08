//+------------------------------------------------------------------+
//|                                                     regtest1.mq4 |
//|                                            (c) 2010 Bernd Kreuss |
//+------------------------------------------------------------------+
#property copyright "(c) 2010 Bernd Kreuss"
#property link      "mailto:prof7bit@googlemail.com"

/**
* This code is released under Gnu General Public License (GPL) V3
* If you need a commercial license then send me an email.
*/

/**
* For this to use you need the following:
*  - install common_functions.mqh
*  - install R  (www.r-project.org)
*  - install mt4R.mqh and mt4R.dll
*  - set RPATH below to point to your R installation
*  - (optional) download and run DebugView.exe
*  - (optional) set RDEBUG to 2 to view more debug info in DebugView
*/

/**
*  You can change base_units if the lot size numbers are too small / too big
*  You can draw a vertical line and name it "back", this will override back_bars
*  You can draw a vertical line and name it "now", it will ignore all bars after this line
*  If you set tick_loop to true you cannnot open the properties dialog anymore but
*  you might need this setting when testing it at weekends.
*/

// set this so that it points to your R installation. Do NOT remove the --no-save
#define RPATH "C:/Programme/R/R-2.11.1/bin/Rterm.exe --no-save"
#define RDEBUG 1

#define SNAPSHOTS "Z:/plots/"

#include <mt4R.mqh>
#include <common_functions.mqh>

extern int back_bars = 2000;
extern int now_bars = 0;
extern int base_units = 100;
extern bool use_diff = true;
extern bool allow_intercept = false;
extern bool Rplot = true;
extern bool AUDUSD = true;
extern bool EURUSD = true;
extern bool GBPUSD = true;
extern bool NZDUSD = true;
extern bool USDCAD = true;
extern bool USDCHF = true;
extern bool USDJPY = true;
extern color clr_spreadline = Yellow;
extern color clr_above = FireBrick;
extern color clr_below = DarkGreen;

#define GLOBALNAME "arbomat"

string symb[0];
double coef[];
double regressors[]; // this flat array is actually representing a matrix
double prices[];
double pred[];
double stddev;
int pairs;
int back;
int now;  // this is the bar offset of the "now" line. use only bars older than now. 
int this;
string ratios;
int time_last;  // time of last bar

void append(string symbol){
   pairs++;
   ArrayResize(symb, pairs);
   symb[pairs-1] = symbol;
}

int init(){
   int i;
   
   pairs = 0;
   if (AUDUSD) append("AUDUSD");
   if (EURUSD) append("EURUSD");
   if (GBPUSD) append("GBPUSD");
   if (NZDUSD) append("NZDUSD");
   if (USDCAD) append("USDCAD");
   if (USDCHF) append("USDCHF");
   if (USDJPY) append("USDJPY");
   this = -1;
   for(i=0; i<pairs; i++){
      if(symb[i] == Symbol()){
         this = i;
         break;
      }
   }
   if (this == -1){
      append(Symbol());
      this = pairs-1;
   }
   
   if (UninitializeReason() != REASON_CHARTCHANGE){
      StartR(RPATH, RDEBUG);
      Rx("options(device='windows')");
   }
   
   
   time_last = 0; // force new bar
}

int deinit(){
   //Rx("save.image(\"" + SNAPSHOTS + "arbomat.R\")");
   plotRemove("others");
   plotRemove("spread");
   ObjectDelete("buy");
   ObjectDelete("sell");
   ObjectDelete("close");
   if (UninitializeReason() != REASON_CHARTCHANGE){
      StopR();
   }
}

void onTick(){
   int units, units1; 
   int i; 
   
   // update the last row
   for (i=0; i<pairs; i++){
      if (symb[i] != Symbol()){
         prices[i] = iClose(symb[i], 0, 0);
      }else{
         prices[i] = 0;
      }
   }
   Rv("current_others", prices);
   Rd("current_this", Close[0]);
   Rx("regressors[1,] <- current_others");
   Rx("regressand[1] <- current_this");
   
   plot();
   
   // buttons for oanda
   if (labelButton("sell", 10, 10, 1, "sell oanda")){
      for (i=0; i<pairs; i++){
         units1 = MathRound(-base_units * coef[i]);
         units = units1 - GlobalVariableGet(GLOBALNAME+Symbol()+Period()+"_"+symb[i]);
         if (units != 0){
            createOandaTicket(symb[i], units);
            GlobalVariableSet(GLOBALNAME+Symbol()+Period()+"_"+symb[i], units1);
            time_last = 0;
         }
      }
   }
   
   if (labelButton("buy", 10, 30, 1, "buy oanda")){
      for (i=0; i<pairs; i++){
         units1 = MathRound(base_units * coef[i]);
         units = units1 - GlobalVariableGet(GLOBALNAME+Symbol()+Period()+"_"+symb[i]);
         if (units != 0){
            createOandaTicket(symb[i], units);
            GlobalVariableSet(GLOBALNAME+Symbol()+Period()+"_"+symb[i], units1);
            time_last = 0;
         }
      }
   }
   
   if (labelButton("close", 10, 50, 1, "close oanda") || autoclose()){
      for (i=0; i<pairs; i++){
         units = -GlobalVariableGet(GLOBALNAME+Symbol()+Period()+"_"+symb[i]);
         if (units != 0){
            createOandaTicket(symb[i], units);
            GlobalVariableSet(GLOBALNAME+Symbol()+Period()+"_"+symb[i], 0);
            time_last = 0;
         }
      }
   }
   
   if (ObjectGet("back", OBJPROP_TIME1) != 0){
      if (iBarShift(NULL, 0, ObjectGet("back", OBJPROP_TIME1)) != back){
         time_last = 0; // enforce onOpen()
      }
   }
   
   
   if (ObjectGet("now", OBJPROP_TIME1) != 0){
      if (iBarShift(NULL, 0, ObjectGet("now", OBJPROP_TIME1)) != now){
         if (iBarShift(NULL, 0, ObjectGet("now", OBJPROP_TIME1)) < back){
            time_last = 0; // enforce onOpen()
         }
      }
   }

   /*
   if (crossedValue(MathAbs(pred[0]), stddev)){
      Alert(Symbol() + " " + Period() + " crossed stddev");
   }
   if (crossedValue(MathAbs(pred[0]), 2 * stddev)){
      Alert(Symbol() + " " + Period() + " crossed 2 * stddev");
   }
   */
}

bool autoclose(){
   string name = "autoclose" + Symbol() + Period();
   double ac = StrToDouble(ObjectDescription(name)) * Point * 10;
   if (ac > 0){
      if (pred[0] > ac){
         ObjectSetText(name, "0");
         return(True);         
      }
   }
   if (ac < 0){
      if (pred[0] < ac){
         ObjectSetText(name, "0");
         return(True);         
      }
   }
   return(False);
}

void onOpen(){
   int i, ii, j;
   int ishift;
   
   // if any pair has less than back bars in the history
   // then adjust back accordingly.
   back = back_bars;
   now = now_bars;
   
   if (ObjectGet("back", OBJPROP_TIME1) != 0){
      back = iBarShift(NULL, 0, ObjectGet("back", OBJPROP_TIME1));
   }
   
   if (ObjectGet("now", OBJPROP_TIME1) != 0){
      now = iBarShift(NULL, 0, ObjectGet("now", OBJPROP_TIME1));
   }
   
   if (now >= back){
      now = 0;
   }
   
   for (i=0; i<pairs; i++){
      if (iBars(symb[i], 0) < back){
         back = iBars(symb[i], 0) - 2; // use the third last bar.
         Print(symb[i], " has only ", back);
      }
   }
   
   ArrayResize(coef, pairs);
   ArrayResize(prices, pairs);
   ArrayResize(regressors, back * pairs);
   ArrayResize(pred, back);
   Ri("back", back);
   Ri("now", now);
   Ri("pairs", pairs);
   
   // fill the matrix of regressors
   // and then copy it over to R
   for (i=0; i<back; i++){
      for (j=0; j<pairs; j++){
         ishift = iBarShift(symb[j], 0, Time[i]);
         regressors[i * pairs + j] = iClose(symb[j], 0, ishift);
      }
   }
   Rm("regressors", regressors, back, pairs);
   
      
   // do the regression
   // first we need a regressand
   Ri("cthis", this + 1);                       // counting starts with 1
   Rx("regressand <- regressors[, cthis]");     // use this column as regressand
   
   Rp("back");
   Rp("length(regressors[,cthis])");
   
   Rx("regressors[, cthis] <- rep(0, back)");   // set the column to zero in the matrix
   if (use_diff){
      Rx("y <- diff(regressand)[seq(now+1,back-1)]");                          
      Rx("x <- diff(regressors)[seq(now+1,back-1),]");
   }else{
      Rx("y <- regressand[seq(now+1,back)]");                          
      Rx("x <- regressors[seq(now+1,back),]");
   }
   if (allow_intercept){                      
      Rx("model <- lm(y ~ x)");                       // fit the model
   }else{
      Rx("model <- lm(y ~ x + 0)");                   
   }
   Rp("summary(model)");
   
   
   // get the coefficients
   if (allow_intercept){                      
      Rgv("coef(model)[-1]", coef);  // the intercept is the first element. throw it away.
   }else{
      Rgv("coef(model)", coef);
   } 
   Rx("stddev <- sd(resid(model))");
   stddev = Rgd("stddev");



   // convert the coefficients to usable hege ratios by multiplying
   // usd/xxx pairs with their quote. The results can then be
   // conveniently interpreted as multiples of needed Lots or Units.
   // also take care of the special case when fitting a spread 
   // instead a trend
   for (i=0; i<pairs; i++){
      // if we fit a spread then all pairs except this one are on the other 
      // side (negative) and this one (the regressand) is 1 by definition
      if (i == this){
         coef[i] = 1;
      }else{
         coef[i] = -coef[i];
      }
      
      // convert to units
      if (StringSubstr(symb[i], 0, 3) == "USD"){ 
         coef[i] = coef[i] * iClose(symb[i], 0, 0);
      }
      
      
      // The following makes sure that if the first pair is an USD/XXX pair
      // it is normalized to 1 again and the lot sizes of the other ones 
      // instead made smaller by the same factor.
      if (StringSubstr(Symbol(), 0, 3) == "USD"){
         coef[i] = coef[i] / Close[0];
      }

   }
   
   // format a string that presents the hedge ratios
   // to the user and that will be displayed in the plot
   // it will also multiply them with base_units so you
   // have some reasonable numbers for your oanda account 
   ratios = formatBool("diff", use_diff) + ", " + formatBool("intercept", allow_intercept) + "\n";
   ratios = ratios + "hedge ratios [multiples of Lots]\n";
   for (i=0; i<pairs; i++){
      ratios = ratios + symb[i] 
      + " " + DoubleToStr(MathRound(base_units * coef[i]), 0) 
      + " (" +  DoubleToStr(GlobalVariableGet(GLOBALNAME+Symbol()+Period()+"_"+symb[i]),0) + ")\n";
   }
   Comment(ratios);

   plot();   
}

void plot(){
   static int last_back;
   // predict and plot from the model
   Rx("pred <- as.vector(predict(model, newdata=data.frame(x=I(regressors))))");
   
   if (last_back != back){
      plotRemove("others");
      plotRemove("spread");
      last_back = back;
   }

   // plot into the chart
   if (use_diff){
      Rgv("pred + mean(regressand[seq(now+1, back-1)]) - mean(pred[seq(now+1, back-1)])", pred); // shift y into view
   }else{
      Rgv("pred", pred);
   }
   plotPrice("others", pred, clr_below, clr_above);
   
   if (use_diff){
      Rx("tmp <- regressand-pred");
      Rgv("tmp - mean(tmp[seq(now+1, back-1)])", pred); 
   }else{
      Rgv("regressand-pred", pred);
   }
   
   plotOsc("spread", pred, 1, 0, clr_spreadline, clr_spreadline);
   label("spread_cur", 10, 70, 1, DoubleToStr(pred[0] / Point / 10, 1), Lime);
   
   // make the R plot
   Rs("descr1", Period() + " minute close prices");
   Rs("descr2", "begin: " + TimeToStr(Time[back-1]) + " -- end: " + TimeToStr(Time[0]));
   Rs("ratios", ratios);
   
   Rx("options(device='windows')");
   Rx("curve <- rev(regressand-pred)");
   if (use_diff){
      Rx("curve <- curve - mean(curve[seq(1, back-now)])");
   }
   Rs("lbly", "spread");
   if(!use_diff){
      Rx("linea <- 0");
      Rx("lineb <- 0");
   }else{
      Rx("mline <- lm(curve[seq(1, back-now)] ~ seq(1, back-now))");
      Rx("linea <- coef(mline)[2]");
      Rx("lineb <- coef(mline)[1]");
      Rx("stddev <- sd(resid(mline))");  // use the standard deviation of this line
      stddev = Rgd("stddev");
   }
   Rx("plot(curve, type='l', ylab=lbly, xlab=descr1, main='Arb-O-Mat', sub=descr2, col='cornflowerblue')");
   Rx("abline(lineb, linea, col='cornflowerblue', lty='dashed')");
   Rx("abline(lineb+stddev, linea, col='green', lty='dashed')");
   Rx("abline(lineb+2*stddev, linea, col='green', lty='dashed')");
   Rx("abline(lineb-stddev, linea, col='green', lty='dashed')");
   Rx("abline(lineb-2*stddev, linea, col='green', lty='dashed')");
   if(now > 0){
      Rx("abline(v=back-now, col='red')");
      Rx("text(back-now-5, range(curve)[1], \"" + TimeToStr(Time[now], TIME_DATE | TIME_MINUTES) + "\", adj=c(1,0), col='red')");
   }
   Rx("text(0, range(curve)[2], ratios, adj=c(0,1), col='black', font=2, family='mono')");
   
   if (IsTesting()){
      // this is used to make the animated backtest.
      //Rx("dev.print(device=png, file=\"" + SNAPSHOTS + Symbol()+Period()+"_"+use_diff+"_"+Time[0] + ".png\", width=480)");
   }
   
   //Rx("save.image(\"" + SNAPSHOTS + "arbomat.R\")");
}

int start(){
   if (Time[0] == time_last){
      onTick();
      return(0);
   }else{
      onOpen();
      onTick();
   }
   time_last = Time[0];
   return(0);
}


void createOandaTicket(string symbol, int units){
   string first = StringSubstr(symbol, 0, 3);
   string last = StringSubstr(symbol, 3, 3);
   string command = first + "/" + last + " " + units;
   string filename = "oanda_tickets/" + TimeCurrent() + "_" + symbol + "_" + units;
   int F = FileOpen(filename, FILE_WRITE);
   FileWrite(F, command);
   FileClose(F);
}


// plotting functions

void plotPrice(string name, double series[], int clra=Red, int clrb=Red){
   int i;
   int len;
   if(IsStopped()) return;
   len = ArraySize(series);
   for (i=1; i<len; i++){
      if(IsStopped()) return;
      ObjectCreate(name + i, OBJ_TREND, 0, 0, 0);
      /*
      ObjectSet(name + i, OBJPROP_TIME1, Time[i-1]);
      ObjectSet(name + i, OBJPROP_TIME2, Time[i]);
      ObjectSet(name + i, OBJPROP_PRICE1, series[i-1]);
      ObjectSet(name + i, OBJPROP_PRICE2, series[i]);
      */
      ObjectSet(name + i, OBJPROP_TIME1, Time[i-1]);
      ObjectSet(name + i, OBJPROP_TIME2, Time[i-1]);
      ObjectSet(name + i, OBJPROP_PRICE1, Close[i-1]);
      ObjectSet(name + i, OBJPROP_PRICE2, series[i-1]);

      ObjectSet(name + i, OBJPROP_RAY, false); 
      ObjectSet(name + i, OBJPROP_BACK, true); 
      if (series[i-1] >= Close[i-1]){
         ObjectSet(name + i, OBJPROP_COLOR, clra);
      }else{
         ObjectSet(name + i, OBJPROP_COLOR, clrb);
      }
   }
}

void plotOsc(string name, double series[], double scale=1, double offset=0, int clra=Red, int clrb=Red){
   int i;
   int len;
   double zero;
   if(IsStopped()) return;
   len = ArraySize(series);
   zero = (WindowPriceMax() + WindowPriceMin())/2 + offset;
   i = 0;
   ObjectCreate(name + i, OBJ_TREND, 0, 0, 0);
   ObjectSet(name + i, OBJPROP_TIME1, Time[0]);
   ObjectSet(name + i, OBJPROP_TIME2, Time[len]);
   ObjectSet(name + i, OBJPROP_PRICE1, zero);
   ObjectSet(name + i, OBJPROP_PRICE2, zero);
   ObjectSet(name + i, OBJPROP_RAY, false); 
   ObjectSet(name + i, OBJPROP_COLOR, clra);
   ObjectSet(name + i, OBJPROP_STYLE, STYLE_DOT);
   for (i=1; i<len; i++){
      if(IsStopped()) return;
      ObjectCreate(name + i, OBJ_TREND, 0, 0, 0);
      ObjectSet(name + i, OBJPROP_TIME1, Time[i-1]);
      ObjectSet(name + i, OBJPROP_TIME2, Time[i]);
      ObjectSet(name + i, OBJPROP_PRICE1, scale * series[i-1] + zero);
      ObjectSet(name + i, OBJPROP_PRICE2, scale * series[i] + zero);
      ObjectSet(name + i, OBJPROP_RAY, false); 
      if (series[i-1]  >= 0){
         ObjectSet(name + i, OBJPROP_COLOR, clra);
      }else{
         ObjectSet(name + i, OBJPROP_COLOR, clrb);
      }
   }
}


void plotRemove(string name, int len=0){
   int i;
   if (len == 0){
      len = Bars;
   }
   for (i=0; i<len; i++){
      ObjectDelete(name + i);
   }
}

bool crossedValue(double value, double level){
   static double old_value = 0;
   bool res = false;
   if (old_value != 0){
      if (value >= level && old_value < level){
         res = true;
      }
      if (value <= level && old_value > level){
         res = true;
      }
   }
   old_value = value;
   return(res);
}

string formatBool(string var, bool value){
   if (value){
      return(var + ": true");
   }else{
      return(var + ": false");
   }
}