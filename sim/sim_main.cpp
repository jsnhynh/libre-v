#include "verilated.h"
#include "verilated_vcd_c.h"

// ----- Stringify helpers -----
#define STR_HELPER(x) #x
#define STR(x) STR_HELPER(x)

// TOP_MODULE should be passed like: -DTOP_MODULE=Valu_tb
#ifndef TOP_MODULE
#  error "TOP_MODULE not defined (pass -DTOP_MODULE=V<top> from your Makefile)"
#endif

// Include the generated header, e.g. "Valu_tb.h"
#include STR(TOP_MODULE.h)

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);

    auto* top = new TOP_MODULE;

    auto* tfp = new VerilatedVcdC;
    top->trace(tfp, 99);
    tfp->open("wave.vcd");

    while (!Verilated::gotFinish()) {
        top->eval();
        tfp->dump(Verilated::time());
        Verilated::timeInc(1);   // REQUIRED for --timing
    }

    tfp->close();
    delete top;
    return 0;
}