#property strict

#include <mt4R.mqh>

extern string R_command = "C:\progs\R-3.0.2\bin\i386\Rterm.exe --no-save";
extern int R_debuglevel = 2;

int rhandle;

int OnInit()
{
   rhandle = RInit(R_command, R_debuglevel);

   return 0;
}

void OnDeinit(const int reason)
{
   RDeinit(rhandle);
}

void OnStart()
{
   int i;
   int k;
   double vecfoo[5];
   double vecbaz[5];

   for (i=0; i<5; i++) {
      vecfoo[i] = SomeThingElse(i);
   }

   RAssignVector(rhandle, "foo", vecfoo, ArraySize(vecfoo));
   RExecute(rhandle, "baz <- foo * 42");
   k = RGetVector(rhandle, "baz", vecbaz, ArraySize(vecbaz));

   for (i=0; i<k; i++) {
      Print(vecbaz[i]);
   }
}

double SomeThingElse(int n)
{
    return 1.25 * n;
}