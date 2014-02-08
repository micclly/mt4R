//+------------------------------------------------------------------+
//|                                                    trendomat.mq4 |
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

extern bool tick_loop = false;
extern int back_bars = 2000;
extern int now_bars = 0;
extern int base_units = 100;
extern bool use_diff = true;
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

#define GLOBALNAME "trendomat"

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
   
   if(IsTesting()){
      // make a matrix that will record some things during a backtest
      Ri("pairs", pairs);
      RAssignStringVector(hR, "tmp", symb, pairs);
      Rx("testhistory <- matrix(nrow=0, ncol=pairs*2)");
      Rx("colnames(testhistory)  <- c(paste('c', tmp), tmp)");
   }
   
   time_last = 0; // force new bar
}

int deinit(){
   if (IsTesting()){
      //Rx("save.image(\"" + SNAPSHOTS + "arbomat.R\")");
   }
   //plotRemove("others");
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
      prices[i] = iClose(symb[i], 0, 0);
   }
   Rv("current_all", prices);
   Rx("regressors[1,] <- current_all");
   
   plot();
   
   // buttons for oanda
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
         time_last = 0;
      }
   }
   
   if (ObjectGet("now", OBJPROP_TIME1) != 0 && now_bars == 0){
      if (iBarShift(NULL, 0, ObjectGet("now", OBJPROP_TIME1)) != now){
         time_last = 0;
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
   
   back = back_bars;
   now = 0;
   
   if (ObjectGet("back", OBJPROP_TIME1) != 0){
      back = iBarShift(NULL, 0, ObjectGet("back", OBJPROP_TIME1));
   }
   
   if (ObjectGet("now", OBJPROP_TIME1) != 0){
      now = iBarShift(NULL, 0, ObjectGet("now", OBJPROP_TIME1));
   }
   
   if (now_bars != 0){ // the value in the properties overrides now (FIXME!)
      now = now_bars;
   }
   
   // if any pair has less than back bars in the history
   // then adjust back accordingly.
   for (i=0; i<pairs; i++){
      if (iBars(symb[i], 0) < back){
         back = iBars(symb[i], 0) - 2; // use the third last bar.
      }
   }
   if (back < now){
      now = 0;
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
   // we simply use a straight line that will be our ideal trend
   Rd("trendslope", 0.01);
   if (use_diff){
      Rx("y <- rep(-trendslope, back-now-1)");                           
      Rx("x <- diff(regressors)[seq(now+1,back-1),]");
   }else{
      Rx("y <- trendslope - trendslope * seq(now+1, back) / back"); 
      Rx("x <- regressors[seq(now+1, back),]");                        
   }
   Rx("model <- lm(y ~ x + 0)");                       // fit the model
   
   // print the model (to the debug monitor)
   Rp("summary(model)");
   
   // get the coefficients
   Rgv("coef(model)", coef); 
   
   if(IsTesting()){
      // record some data during a backtest for later analysis
      Rx("testhistory <- rbind(testhistory, c(coef(model), regressors[now+1,])) ");
   }

   // convert the coefficients to usable hege ratios by multiplying
   // usd/xxx pairs with their quote. The results can then be
   // conveniently interpreted as multiples of needed Lots or Units.
   for (i=0; i<pairs; i++){
      
      // convert to units
      if (StringSubstr(symb[i], 0, 3) == "USD"){ 
         coef[i] = coef[i] * iClose(symb[i], 0, 0);
      }

   }
   
   // format a string that presents the hedge ratios
   // to the user and that will be displayed in the plot
   // it will also multiply them with base_units so you
   // have some reasonable numbers for your oanda account 
   ratios = "base_units: " + base_units + ", " + formatBool("use_diff", use_diff) + "\n";
   ratios = ratios + "hedge ratios [multiples of Lots]\n";
   for (i=0; i<pairs; i++){
      ratios = ratios + symb[i] 
      + " " + DoubleToStr(MathRound(base_units * coef[i]), 0) 
      + " (" +  DoubleToStr(GlobalVariableGet(GLOBALNAME+Symbol()+Period()+"_"+symb[i]),0) + ")\n";
   }
   Comment(ratios);

   plot(); // FIXME: nasty side effect: the plot function does also calculate stddev
}

void plot(){
   static int last_back;
   // predict and plot from the model
   Rx("pred <- as.vector(predict(model, newdata=data.frame(x=I(regressors))))");
   

   Rs("descr1", Period() + " minute close prices");
   Rs("descr2", "begin: " + TimeToStr(Time[back-1]) + " -- end: " + TimeToStr(Time[0]));
   Rs("ratios", ratios);
   
   Rx("options(device='windows')");
   if (use_diff){
      Rx("curve <- rev(pred) - pred[back-1]");  // it is still ordered backwards, so we reverse it now
      Rx("mline <- lm(curve[seq(1, back-now)] ~ seq(1, back-now))");
      Rx("linea <- coef(mline)[2]");
      Rx("lineb <- coef(mline)[1]");
      Rx("stddev <- sd(resid(mline))");  // use the standard deviation of this line
   }else{
      Rx("curve <- rev(pred)");          // it is still ordered backwards, so we reverse it now
      Rx("linea <- trendslope/back");
      Rx("lineb <- 0");
      Rx("stddev <- sd(resid(model))");  // the sd is that of the original model
   }
   Rs("lbly", "combined returns");
   Rx("plot(curve, type='l', ylab=lbly, xlab=descr1, main='Trend-O-Mat', sub=descr2, col='cornflowerblue')");
   
   if(now > 0){
      Rx("abline(v=back-now, col='red')");
      Rx("text(back-now-5, range(curve)[1], \"" + TimeToStr(Time[now], TIME_DATE | TIME_MINUTES) + "\", adj=c(1,0), col='red')");
   }
   Rx("abline(lineb, linea, col='cornflowerblue', lty='dashed')");
   Rx("abline(lineb+stddev, linea, col='green', lty='dashed')");
   Rx("abline(lineb+2*stddev, linea, col='green', lty='dashed')");
   Rx("abline(lineb-stddev, linea, col='green', lty='dashed')");
   Rx("abline(lineb-2*stddev, linea, col='green', lty='dashed')");
   
   
   Rx("text(0, range(curve)[2], ratios, adj=c(0,1), col='black', font=2, family='mono')");
   
   if (IsTesting()){
      //Rx("dev.print(device=png, file=\"" + SNAPSHOTS + Symbol()+Period()+"_"+use_diff+"_"+Time[0] + ".png\", width=480)");
   }

   
   label("trend_cur", 10, 70, 1, DoubleToStr(Rgd("curve[length(curve)]") / Point / 10, 1), Lime);
   
   // get the standard deviation into an mql4 variable, we might need it later.
   stddev = Rgd("stddev");
}

int start(){
   while (!IsStopped()){
      RefreshRates();
      if (Time[0] != time_last){
         onOpen();
         time_last = Time[0];
      }
      onTick();
      
      if (tick_loop){
         Sleep(1000);
      }else{
         break;
      }
   }
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