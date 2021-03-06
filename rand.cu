/* kernel routine starts with keyword __global__ */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <time.h>
#include <sys/time.h>
#include <math.h>

// CUDA includes
#include <cuda.h>
#include <curand.h>
#include <curand_kernel.h>

// Root includes
#include <TFile.h>
#include <TH1.h>
#include <TH2.h>

// calo parameters
#define NXSEG 9
#define NYSEG 6
#define NSEG 54

// Qmethod parameters
#define TIMEDECIMATION 16
#define GEVTOADC  2048./6.2
#define  PEAKBINFRAC  0.4

// simulator parameters
#define NEMAX 5000 // max electrons per fill per calo
#define NTMAX 6    // max threshold histograms

// output root file
TFile *f;

// output histograms
TH1D *hHits1D, *hPUHits1D, *hEnergy1D, *hPUlostEnergy1D, *hPUgainEnergy1D; // diagnostics histograms of truth hit time, energy distributions
TH1D *hFlush1D[NSEG*NTMAX], *hLastFlush1D[NSEG*NTMAX], *hNextLastFlush1D[NSEG*NTMAX], *hPUFlush1D[NSEG*NTMAX], *hFlush1Dlost[NSEG*NTMAX], *hStats1D[NSEG*NTMAX], *htmp[NSEG*NTMAX]; // per xtal, 1D q-method time distributions (above / below threshold setting)
TH2D *hFlush2D[NSEG], *hFlush2DCoarse[NSEG]; // per xtal, 2D q-method time distribution
TH2D *hFlush2DSum, *hFlush2DCoarseSum; // per calo, 2D q-method time distribution

float toddiff(struct timeval*, struct timeval*);

// function for calculation time intervals                                                               
float toddiff(struct timeval *tod2, struct timeval *tod1) {
  float fdt, fmudt;
  long long t1, t2, mut1, mut2;
  long long dt, mudt;

  t1 = tod1->tv_sec;
  mut1 = tod1->tv_usec;
  t2 = tod2->tv_sec;
  mut2 = tod2->tv_usec;
  dt = ( t2 - t1);
  mudt = ( mut2 - mut1);
  fdt = (float)dt;
  fmudt = (float)mudt;

  return fdt + 1.0e-6*fmudt;
}

/* 
   GPU kernel function to initialize the random states.
Each thread gets same seed, a different sequence number, 
and no offset 
*/
__global__ void init_rand( curandState *state, unsigned long long offset, unsigned long long seed) {

   // thread index
   int idx = blockIdx.x*256 + threadIdx.x;

   curand_init( seed, idx, 0, &state[idx]);
}

/*
GPU kernel utility function to initialize fill/flush data arrays
*/
__global__ void zero_int_array( int32_t *array, int length) {

   // thread index
  int idx = blockIdx.x*256 + threadIdx.x;

  if (idx < length) *(array + idx) = 0;
}

/*
GPU kernel utility function to initialize fill/flush data arrays
*/
__global__ void zero_float_array( float *array, int length) {

   // thread index
  int idx = blockIdx.x*256 + threadIdx.x;
  if (idx < length) {
    *(array + idx) = 0.0;
  }
}

/*
GPU kernel user function to build uniform time distribution
*/
__global__ void make_rand( curandState *state, float *randArray) {

   // thread index
   int idx = blockIdx.x*256 + threadIdx.x;

   curandState localState = state[idx];
   randArray[idx] = curand_uniform( &localState);
   state[idx] = localState;
}

/*
GPU kernel user function to build decay curve distribution
*/
__global__ void make_randexp( curandState *state, float *randArray, float tau) {

   // thread index
   int idx = blockIdx.x*256 + threadIdx.x;

   curandState localState = state[idx];
   randArray[idx] = -tau * log( 1.0 -curand_uniform(&localState) );
   state[idx] = localState;
}

/*
GPU kernel user function to build each fills time distribution
*/
__global__ void make_randfill( curandState *state, int32_t *hitArray, int32_t *fillArray, float *hitSumArray, float *PUhitSumArray, float *fillSumArray,  float *energySumArray, float *PUlostenergySumArray, float *PUgainenergySumArray, int ne, int fill_buffer_max_length, int nfills, bool fillnoise) {

  // single thread make complete fill with ne electrons

   const float tau = 6.4e4;                              // muon time-dilated lifetime (ns)
   const float omega_a = 1.438e-3;                       // muon anomalous precession frequency (rad/ns)
   const float magicgamma = 29.3;                        // gamma factor for magic momentum 3.094 GeV/c
   const float GeVToADC = GEVTOADC;                      // energy-ADC counts conversion (ADC counts / energy GeV)
   const float peakBinFrac = PEAKBINFRAC;                // fraction of calo pulse in single 800 MHz digitizer bin
   const int nsPerTick = TIMEDECIMATION*1000/800;        // Q-method histogram bin size (ns), accounts for 800MHz sampling rate
   const float Elab_max = 3.095;                         // GeV, maximum positron lab energy
   const float Pi = 3.1415926;                           // Pi
   const float cyclotronperiod = 149.0/nsPerTick;        // cyclotron period in histogram bin units
   const float anomalousperiod = 4370./nsPerTick;        // anomalous period omega_c-omega_s in histogram bin units
   const int nxseg = NXSEG, nyseg = NYSEG, nsegs = NSEG; // calorimeter segmentation

   // parameters for empirical calculation of positron drift time calculation from energy via polynomial
   float p0 =    -0.255134;
   float p1 =      65.3034;
   float p2 =     -705.492;
   float p3 =      5267.21;
   float p4 =     -23986.5;
   float p5 =      68348.1;
   float p6 =      -121761;
   float p7 =       131393;
   float p8 =       -78343;
   float p9 =      19774.1;

   // parameters to mimic first-order pileup in T-method (no spatial resolution of pulse pileup)
   float PUtick, prevtick, prevADC; // mimic T-method pileup
   float PUdt = 10.0/nsPerTick; // convert from ns to clock ticks
   float PUth = 1.8*GeVToADC/peakBinFrac; // convert from GeV to ADC value
   //PUdt = 0.0/nsPerTick; // switch off PU
   //PUth = 0.0*GeVToADC/peakBinFrac; // switch off PU

   // variables for muon decay / kinematics 
   float t, y, A, n;   // mu-decay parameters
   float r, r_test;    // mu decay rate 

   // thread index
   int idx = blockIdx.x*256 + threadIdx.x;

   // one thread per fill
   if (idx < nfills) {

     // state index for random number generator
     curandState localState = state[idx];
     
     // make noise for each fill if fillnoise true (time consuming)
     if (fillnoise) {

       float pedestal = 0., sigma = 4.; // paramters for noise distribution

       int32_t noise; 
       for (int i = 0; i < nsegs*fill_buffer_max_length; i++){

	 noise = pedestal + sigma * curand_normal(&localState); // generate Gaussian noise using normal distribution
         atomicAdd( &(fillSumArray[ i ]), (float)noise );       // add fill-by-fill noise to flush buffer
       }
     }
     
     int nhit = 0; // good hit counter
     float theta = 0; // decay angle
     
     // parameters for positron x,y, time
     float xrand, yrand, xmax; // x,y coordinate random numbers and endpoint of hit distribution across calo x-coordinate
     
     // parameters for calculating the positron drift time
     float ylab, phase, drifttime; 

     // paraters for positron time, ADC counts, and x/y coordinates
     float tick, ADC, xcoord, ycoord; 
     
     // arrays for storing the hit information before time-ordering (ADCnorm is used for pile-up correction)
     float tickstore[NEMAX], ADCstore[NEMAX], xcoordstore[NEMAX], ycoordstore[NEMAX];
     int  iold[NEMAX];

     // find hit times, energies, x-coordinate, y-coordinate for ne generated electrons from muon decay
     while (nhit < ne){ // should randomize the hits per fill

       // Get muon decay time     
       t = -tau * log( 1.0 - curand_uniform(&localState) );     // random from exp(-t/tau) using uniform random number 0->1
       tick = t/nsPerTick;                                      // convert from ns to Q-method histogram bins
       if ( ( (int)tick ) >= fill_buffer_max_length ) continue; // time out-of-bounds 
       
       // Get positron lab energy. Obtained by generating the position energy, angle distribution in muon rest frame

       /*
       // original version with calculation done in muon rest frame
       y = curand_uniform(&localState);
       A = (2.0*y - 1)/(3.0 - 2.0*y);
       n = y*y*(3.0 - 2.0*y);
       r_test = n*(1.0-A*cos(omega_a*t))*0.5; 
       r = curand_uniform(&localState);  
       if ( r >= r_test ) continue;

       theta = Pi*curand_uniform(&localState); 
       float Elab = 0.5 *Elab_max * y * ( 1.0 + cos(theta)); 
       */

       // new version with calculation done in muon rest frame
       y = curand_uniform(&localState);
       A = (-8.0*y*y + y + 1.)/( y*y - 5.*y - 5.);
       n = (y - 1)*( y*y - 5.*y - 5.);
       r_test = n*(1.-A*cos(omega_a*t))/6.; 
       r = curand_uniform(&localState);  
       if ( r >= r_test ) continue;

       float Elab = Elab_max*y;

       // Account for acceptance of calorimeter using empirical, energy-dependent calo acceptance
       // for now a very simple empirical acceptance, zero below ElabMin, unit above ElabMin

       //float ElabMin = 0.5; // acceptance cutoff
       //if (Elab < ElabMin) continue;

       // simple acceptance paramterization from Aaron see Experiments/g-2/Analysis/Qmethod/functionForTim.C
       if (Elab > 0.7*Elab_max) {
	 r_test = 1.0;
       } else {
	 r_test = Elab/(0.7*Elab_max);
       }
       r = curand_uniform(&localState);  
       if ( r >= r_test ) continue;

       // Variable ADC is total ADC samples of positron signal at 800 MMz sampling rate with 6.2 GeV max range over 2048 ADC counts
       ADC = GeVToADC*Elab; 

       // Divide by maximum fraction of positron signal in single 800 MHz bin (is ~0.4 from erfunc plot of 5ns FWHM pulse 
       // in peak sample at 800 MHz sampling rate
       ADC = ADC/peakBinFrac; 

       // Add empirical energy-dependent drift time, see https://muon.npl.washington.edu/elog/g2/Simulation/229 
       // using empirical distribution for relation between energy and time
       ylab = Elab/Elab_max;
       phase = p0 + p1*ylab + p2*ylab*ylab + p3*ylab*ylab*ylab + p4*ylab*ylab*ylab*ylab 
	 + p5*ylab*ylab*ylab*ylab*ylab + p6*ylab*ylab*ylab*ylab*ylab*ylab + p7*ylab*ylab*ylab*ylab*ylab*ylab*ylab 
	 + p8*ylab*ylab*ylab*ylab*ylab*ylab*ylab*ylab + p9*ylab*ylab*ylab*ylab*ylab*ylab*ylab*ylab*ylab; // phase in mSR units of omega_a
       drifttime = anomalousperiod * phase / (2.*Pi*1000.); // convert the omega_a phase to drift time in Q-method histogram bin units
       tick = tick + drifttime;
       
       // generate the x, y coordinates of positron hit on calorimeter

       // simple random (x, y) coordinates
       //xcoord = nxseg * curand_uniform(&localState);
       //ycoord = nyseg * curand_uniform(&localState);
       
       // make rough empirical x-distribution obtained from  https://muon.npl.washington.edu/elog/g2/Simulation/258 (Robin)
       // and rough empirical y-distribution obtained from  https://muon.npl.washington.edu/elog/g2/Simulation/256 (Pete)
       if ( ylab > 0.7 ) {
	 xmax = 185.-533.3*(ylab-0.7);
       } else {
	 xmax = 185.;
       }
       xrand = curand_uniform(&localState);
       xcoord = xmax*xrand/25.0; // x-coordinate -> mm -> segments
       yrand = curand_uniform(&localState);
       ycoord = 1.0+(nyseg-2.0)*yrand; // y-coordinate -> segments

       // q-method histogram bin from decay time in bin units
       int itick = (int)tick;

       // hit arrays are arrays of xtal-summed calo hits (not individual xtal hits) for diagnostics
       // if using hitSumArray flush buffer
       //atomicAdd( &(hitSumArray[ itick ]), 1.0);
       if ( ADC > PUth ) atomicAdd( &(hitSumArray[ itick ]), 1.0);
       // if using hitArray flush buffer
       //hitArray[ itick + fill_buffer_max_length*idx ]++; 

       // energy arrays of true energy of each hit (not individual xtal energies) for diagnostics
       // if using energySumArray flush buffer
       atomicAdd( &(energySumArray[ (int)ADC ]), 1.0);
       // if using hitArray flush buffer
       //hitArray[ ADC + energybins*idx ]++; 
       
       // put hit information (time, ADC counts, x/y coordinates, hit index) into hit array
       // used in time-ordering the hits that's needed for applying pile-up effects
       tickstore[nhit] = tick;
       ADCstore[nhit] = ADC;
       xcoordstore[nhit] = xcoord;
       ycoordstore[nhit] = ycoord;
       iold[nhit] = nhit;
       nhit++;
     }
     //printf("fill %i, hits %i\n", idx, nhit);
     
     // sort array of positron hits into ascending time-order
     int itemp;
     float temp;
     for (int i = 0; i < nhit; ++i) {
       for (int j = i + 1; j < nhit; ++j) {
	 // if higher index array element j is earlier (t_j < t_i) than lower index  array element i then swap elements
	 if (tickstore[i] > tickstore[j]) {
	   // swap times if hit i is later than hit j
	   temp = tickstore[i]; 
	   tickstore[i] = tickstore[j];
	   tickstore[j] = temp;
	   // swap indexes if hit i is later than hit j for later use in swapping ADC, x, y coordinates
	   itemp = iold[i]; 
	   iold[i] = iold[j];
	   iold[j] = itemp;
	 }
       }
     }

     // simple test of pileup effect - doesn't handle the segmentation and effect of amplitude of prior pulse
     // short-term gain-change time constant 30ns, amplitude 4%/1000 
     // long-term gain-change time constant 10us, amplitude 0.012/(1000*(1-exp(-10./64.)) ~ 10^-4 
     // see SIPM paper https://arxiv.org/pdf/1611.03180.pdf
     //float tauG = 10000.0/nsPerTick, ampG = 0.001;
     /*
     for (int j = 1; j < nhit; j++){
       for (int k = 0; k < j; k++){

     	float dt = tickstore[j] - tickstore[k];
	ADCstore[iold[j]] *= 1.0 - ampG*exp(-dt/tauG); 
       }
     }
     */

     // parameters for distributing the ADC counts over calo xtals.
     // parameters for empirical Gaussian distribution of energy across neighboring segments. Used 
     // https://muon.npl.washington.edu/elog/g2/SLAC+Test+Beam+2016/260 and position where energy in 
     // neighboring xtal is 16% (1 sigma) - giving sigma = 0.19 in units of crystal size 
     //float xsig = 0.01, ysig = 0.01; // test with very small spread
     //float xsig = 0.5, ysig = 0.5; // test with very large spread
     float xsig = 0.19, ysig = 0.19; // xtal size units
     
     // parameters for distributing the ADC counts over time bins of q-method histogram
     // approx sigma width of 2.1ns from https://muon.npl.washington.edu/elog/g2/SLAC+Test+Beam+2016/38
     //const float width = 0.21/nsPerTick; // test - make pulse width x10 smaller
     //const float width = 21.0/nsPerTick; // test  - make pulse width x10 larger
     const float width = 2.1/nsPerTick; // pulse sigma in q-method bin width units

     // parameters for pile-up effects
     // simple time constant, pulse amplitude and normalization paramter of pileup effect of prior pulses
     float tauG = 30.0/nsPerTick;
     float ampG = 0.04;
     float ADCnorm = 812;

     float ADCstoresegment[54][NEMAX]; // array used for xtal-by-xtal pileup effects
 
     // loop over time-ordered positron hits
     for (int i = 0; i < nhit; i++){
       
       // time array is already time-ordered
       tick = tickstore[i]; 
       // other arrays aren't already time-ordered
       ADC = ADCstore[iold[i]];
       xcoord = xcoordstore[iold[i]];
       ycoord = ycoordstore[iold[i]];


       // PU hit arrays are arrays of xtal-summed calo hits (not individual xtal hits) for diagnostics
       // that include a pile-up time window and a energy threshold and mimic a simple T-method.
       // handles double pile-up, not triple pileup, etc
       if (i == 0 ) {

	 if ( ADC > PUth ) atomicAdd( &(PUhitSumArray[ (int)tick ]), +1.0); // add first hit if above threshold
	 //printf("fill %i, first hit i %i, t_i %f, A_i, %f \n", idx, i, tick, ADC);
       } else {

	 prevtick = tickstore[i-1]; 
	 
	 if ( tick-prevtick < PUdt ){
           
	   // pile-up in time
	   prevADC = ADCstore[iold[i-1]]; 
           PUtick = ( prevADC*prevtick + ADC*tick )/( prevADC + ADC );
	   //printf("pileup: fill %i, hit %i t = %f, hit %i, t = %f\n", idx, i-1, prevtick, i, tick);
           // build array of energy of losses / gains of hits due to pileup
	   if ( (prevADC + ADC) > PUth ) { 
	     atomicAdd( &(PUlostenergySumArray[ (int)prevADC ]), +1.0);
	     atomicAdd( &(PUlostenergySumArray[ (int)ADC ]), +1.0);
	     atomicAdd( &(PUgainenergySumArray[ (int)(prevADC+ADC) ]), +1.0);
	   }
	   if ( prevADC > PUth ) {
	     atomicAdd( &(PUhitSumArray[ (int)prevtick ]), -1.0); // remove previous hit if above threshold
	     //printf("remove pile-up hit: fill %i, %i, time %f, ADC %f, thres %f\n", idx, i-1, prevtick, prevADC, PUth);
	   }
 	   if ( (prevADC + ADC) > PUth ) {
	     atomicAdd( &(PUhitSumArray[ (int)PUtick ]), +1.0); // add pileup hit if above threshold
	     //printf("add pile-up hit: fill %i, %i, time %f, ADC %f, thres %f\n", idx, i, PUtick, prevADC+ADC, PUth);
	   }
           //printf("fill %i, ith hit %i, t_i-1, t_i, t_PU, %f, %f, %f, A_i-1, A_i, A_PU, %f, %f, %f, PUdt %f, PUth %f\n", 
	   //		  idx, i, prevtick, tick, PUtick, prevADC, ADC, prevADC+ADC, PUdt, PUth);
	 } else {
	   
	   //printf("fill %i, ith hit i %i, t_i %f, A_i, %f, thres %f\n", idx, i, tick, ADC, PUth);
	   if ( ADC > PUth ) atomicAdd( &(PUhitSumArray[ (int)tick ]), +1.0); // if no-pileup add current hit if above threshold
	 }
       }
 
       // itick is bin of q-method time histogram
       // rtick is time within bin of q-method time histogram
       int itick = (int)tick;
       float rtick = tick - itick;

       // loop over the array of xtals and distribute the total ADC counts (ADC) to each xtal (ADC segment)
       // using the hit coordinates xcoord, ycoord and distribution paramters xsig, ysig. 
       float fsegmentsum = 0.0; // diagnostic parameter for distribution of energy over segments
       for (int ix = 0; ix < nxseg; ix++) {
	 for (int iy = 0; iy < nyseg; iy++) {
	   
	   // energy in segment (assume a Gaussian distribution about xc, yc
           float fsegmentx = 0.5*(-erfcf((ix+1.0-xcoord)/(sqrt(2.)*xsig))+erfcf((ix-xcoord)/(sqrt(2.)*xsig)));
	   float fsegmenty = 0.5*(-erfcf((iy+1.0-ycoord)/(sqrt(2.)*ysig))+erfcf((iy-ycoord)/(sqrt(2.)*ysig)));
           float fsegment = fsegmentx*fsegmenty;
	   float ADCsegment = fsegment*ADC;
           fsegmentsum += fsegment;

	   if (ADCsegment < 1.0) continue; // avoid pileup calc if signal in xtal is neglibible
           
           // handle pulse-pileup on segment-to-segment basis

	   /* xtal-by-xtal pileup calculation

	   // store ADC counts of "fired" xtal
	   ADCstoresegment[ix+iy*nxseg][i] = ADCsegment; // store samples of "fired" segment

           // handle pileup correction on segment-by-segment basis by looping over prior hits
           // uses pileup parameters ampG, tauG
	   for (int ipu = 0; ipu < i; ipu++) {
	     float dt = tickstore[i] - tickstore[ipu];
	     ADCsegment *= 1.0 - (ADCstoresegment[ix+iy*nxseg][i]/ADCnorm)*ampG*exp(-dt/tauG);
	   }

	   */

	   // offset needed for storing xtal hits in samples array
	   int xysegmentoffset = (ix+iy*nxseg)*fill_buffer_max_length; 
	   
	   // do time smearing of positron pulse over several contiguous time bins
           // just loop over bins k-1, k, k+1 as negligible effect for other bins   
	   float tfracsum = 0.0; // diagnostic for distribution of energy over segments
	   for (int k=-1; k<=1; k++) {

	     int kk = k + itick;
	     if ( kk < 0 || kk >= fill_buffer_max_length ) continue;

              // energy in bin (assume a Gaussian distribution about tick (time within central bin)
	     float tfrac = 0.5*(-erfcf((kk+1.0-tick)/(sqrt(2.)*width))+erfcf((kk-tick)/(sqrt(2.)*width)));
             float ADCfrac = ADCsegment*tfrac; 
	     tfracsum += tfrac;

	     if ( ADCfrac > 2048 ) ADCfrac = 2048; // apply overflow of ADC counts

             // if using fillArray fill buffer
	     //if ( ADCfrac >= 1 ) *(fillArray + nsegs*fill_buffer_max_length*idx + xysegmentoffset + kk ) += ADCfrac;  // fill buffer
             // if using fillSumArray flush buffer
	     if ( ADCsegment >= 1 ) atomicAdd( &(fillSumArray[ xysegmentoffset + kk ]), ADCfrac );

	   } // end of time smearing

           // for no time smearing all xtal ADC counts in single time bin
	   //atomicAdd( &(fillSumArray[ xysegmentoffset + itick ]), (float)ADCsegment );

           // simple-minded testing of effects of tail of SiPM pulse
           // e.g. the problem with long tails on SiPM pulses from AC coupling

	   /*
	   int maxtaillength = 2000; // max tail length calculation  in q-method hostigrma bins
           float tailamp = -1.0e-3, tailtail = 1000.; // pulse tail parameters

	   for (int k = 0; k <= maxtaillength; k++) {
	     int kk = k + itick;

	     if ( kk < 0 || kk >= fill_buffer_max_length ) continue;

	     // energy in bin (assume a Gaussian distribution about tick
	     float tfrac = tailamp*exp(-float(k)/tailtau); // exponential tail
             float ADCfrac = ADCsegment*tfrac; // need to add some noise
	     tfracsum += tfrac;

	     if ( ADCfrac > 2048 ) ADCfrac = 2048;

             // if using fillArray fill buffer
	     //if ( ADCfrac >= 1 ) *(fillArray + nsegs*fill_buffer_max_length*idx + xysegmentoffset + kk ) += ADCfrac;  // fill buffer
             // if using fillSumArray flush buffer
	     if ( ADCsegment >= 1 ) atomicAdd( &(fillSumArray[ xysegmentoffset + kk ]), ADCfrac );

	   } // end of ADC taile
	   */

	 } // y-distribution loop
       } // x-distribution loop

     } // time-ordered hits hits
     
     // state index for random number generator
     state[idx] =  localState;
     
     /*
     // fill pattern for testing 
     for (int i = 0; i < nsegs; i++) {
     
     for (int j = 0; j < fill_buffer_max_length; j++) {
     
     *(fillArray + nsegs*fill_buffer_max_length*idx + fill_buffer_max_length*i + j) += i;  // fill buffer
     }
     }
     */
     
   } // enf of if idx < nfills
}

/*
GPU kernel function - builds fillSumArray from fillArray if fillArray is used and introduces noise at flush-level
*/
__global__ void make_fillsum( curandState *state, int32_t *fillArray, float *fillSumArray, int nfills, int fill_buffer_max_length, bool flushnoise ) {

  // thread index
  int idx = blockIdx.x*256 + threadIdx.x;
  curandState localState = state[idx];

  int nxsegs = NXSEG, nysegs = NYSEG, nsegs = NSEG;
  
  // fill_buffer_max_length is Q-method bins per segment per fill
  if (idx < nsegs * fill_buffer_max_length) {

    // add all the fills in flush
    for (int i = 0; i < nfills; i++) {
      *(fillSumArray + idx) += (float) *(fillArray + (nsegs*fill_buffer_max_length)*i + idx );  // fill buffer
    }

    // add noise at flush level
    if (flushnoise) {
      float pedestal = 0., sigma = 4.; // parameters of noise at flush level
      float noise = pedestal + sigma * curand_normal(&localState); // random from Gaussian using uniform random number 0->1
      *(fillSumArray + idx) += noise;  // fill buffer
      state[idx] = localState;
    }
 
  }
}

/*
GPU kernel function - builds fillSumArray from fillArray if fillArray is used and introduces noise at flush-level
*/
__global__ void add_flushnoise( curandState *state, float *fillSumArray, int nfills, int fill_buffer_max_length) {

  // thread index
  int idx = blockIdx.x*256 + threadIdx.x;
  curandState localState = state[idx];

  const int nxsegs = NXSEG, nysegs = NYSEG, nsegs = NSEG;
  const int nsPerTick = TIMEDECIMATION*1000/800;        // Q-method histogram bin size (ns), accounts for 800MHz sampling rate
  
  // fill_buffer_max_length is Q-method bins per segment per fill
  if (idx < nsegs * fill_buffer_max_length) {

    int iseg = idx / fill_buffer_max_length;
    int ibin = idx % fill_buffer_max_length;

    // for parameter values see ~/Experiments/g-2/Analysis/June2017/tailstats.ods
    float shrt_tau = 14000./nsPerTick; // shrt pedestal lifetime ns->ticks 
    float long_tau = 77000./nsPerTick; // long pedestal lifetime ns->ticks
    float shrt_ampl = 9.1; // amplitude of shrt pedestal lifetime at t=0 in ADC counts per single fill
    float long_ampl = 2.7; // amplitude of long pedestal lifetime at t=0 in ADC counts per single fill
    shrt_ampl = shrt_ampl*TIMEDECIMATION;
    long_ampl = long_ampl*TIMEDECIMATION;

    // add pedestal and statistical noise at flush level

    float prodtocom = -1.0; // commissioning to production run normalization factor of pedestal variation per fill (note sign)
    //float prodtocom = -0.17; // commissioning to production run normalization factor of pedestal variation per fill (note sign)
    //float prodtocom = 0.0; // commissioning to production run normalization factor of pedestal variation per fill
    float pedestal = prodtocom * nfills * ( shrt_ampl*exp(-float(ibin)/shrt_tau) + long_ampl*exp(-float(ibin)/long_tau) ); // xtal independent 
    float sigma = sqrt((float)nfills)*4.0; // parameters of noise at flush level, noise per single fill to noise per nfill flush
    //float noise = pedestal + sigma * curand_normal(&localState); // random from Gaussian using uniform random number 0->1
    float noise = pedestal; // just pedestal
    *(fillSumArray + idx) += noise;  // fill buffer
    state[idx] = localState;
    
  }
}

/*
GPU kernel function - builds hitSumArray from hitArray if hitArray is used
*/
__global__ void make_hitsum( int32_t *hitArray, float *hitSumArray, int nfills, int fill_buffer_max_length, bool flushnoise) {

  int idx = blockIdx.x*256 + threadIdx.x;
  
  // fill_buffer_max_length is Q-method bins per segment per fill
  if (idx < fill_buffer_max_length) {
    
    // initialize flush to zero (now use cudaMemset)
    //  *(hitSumArray + idx) = 0.0;
    
    // add fills in flush
    for (int i = 0; i < nfills; i++) {
      *(hitSumArray + idx) += (float) *( hitArray + (fill_buffer_max_length)*i + idx );  // fill buffer
    }   
  }
}


/*
GPU kernel function - builds energySumArray from energuArray if energyArray is used
*/
__global__ void make_energysum( int32_t *energyArray, float *energySumArray, int nfills, int fill_buffer_max_length, bool flushnoise) {

  int idx = blockIdx.x*256 + threadIdx.x;
  
  // fill_buffer_max_length is Q-method bins per segment per fill
  if (idx < fill_buffer_max_length) {
    
    // initialize flush to zero (now use cudaMemset)
    //  *(energySumArray + idx) = 0.0;
    
    // add fills in flush
    for (int i = 0; i < nfills; i++) {
      *(energySumArray + idx) += (float) *( energyArray + (fill_buffer_max_length)*i + idx );  // fill buffer
    }   
  }
}

/* 
main program

usage
./rand ne nfills nflushes thresholdinterval thresholdnumber 

where arguments are number of electrons in fill, number of fills in flush, number of flushes in run, and threshold
applied at flush level

*/
int main(int argc, char * argv[]){

  cudaError err;
 
  // define nthreads, nblocks, arrays for GPU
  int nthreads = 256, nblocks1, nblocks2, nblocks3, nblocks4, nblocks5;

  // parameters for number of electrons in fill, number of fills in flush, and flushes in run
  int ne, nfills, nflushes, nthresholds;
  // parameter for qmethod threshold, Set to -999 for zero-threshold qmethod. this threshold is applied to flushes not fills 
  float threshold;

  // for state of randum generators
  curandState *d_state, *d_state2;
  float *h_randArray, *d_randArray;

  // Q-method arrays 
  int32_t *h_fillArray, *d_fillArray;
  float *h_fillSumArray, *d_fillSumArray; 
  // for hits arrays 
  int32_t *h_hitArray, *d_hitArray;
  float *h_hitSumArray, *d_hitSumArray; 
  // for PU hits arrays 
  float *h_PUhitSumArray, *d_PUhitSumArray; 
  // for energy array
  int32_t *h_energyArray, *d_energyArray;
  float *h_energySumArray, *d_energySumArray; 
  // for PU energy array
  float *h_PUlostenergySumArray, *d_PUlostenergySumArray; 
  float *h_PUgainenergySumArray, *d_PUgainenergySumArray; 

  // define fill length, clock tick for simulation
  //const int nsPerFill = 4096, nsPerTick = 16; 
  //const int nsPerFill = 560000, nsPerTick = 16; 
  const int nsPerFill = 560000, nsPerTick = TIMEDECIMATION*1000/800; 
  const float  GeVToADC = GEVTOADC, PeakBinFrac = PEAKBINFRAC;

  int fill_buffer_max_length = nsPerFill / nsPerTick; // fill length in unit of hostogram bins
  int nxsegs = NXSEG, nysegs = NYSEG, nsegs = NSEG; // calo segmentation parameters
  int energybins = 8192; // number of energy histogram bins
 
  // define run, flush, fill structure from command line arguments
  printf("number of argurments of command %i\n", argc); 
  if (argc == 1) {
    ne = 5500;   // on average 1100 good e's per fill, 5500 e's per fill
    nfills = 256;
    nflushes = 1;
    threshold = -999.; // -999. for zero-threashold qmethod
    nthresholds = 1; // number of steps of threshold
  } else {
    ne = atoi(argv[1]);
    nfills = atoi(argv[2]);
    nflushes = atoi(argv[3]);
    threshold = atoi(argv[4]);
    nthresholds = atoi(argv[5]);
  }

  // from TDR 
  // events for 100ppb stat uncertainty, 1.6e11
  // >30us, >1.86 GeV positrons for 24 calos per fill, 1100
  // positrons for 24 calos per fill, 5500 (from TDR Fig 16.8 for energy and exp(-t/tau) for time) 
  // fills for 140 ppb, 1.5e8
  // from elog
  // we need 1.6e11 events to reach 100ppb statistical precision. (TDR page 119)
  // will acquire the 1.6x10e11 events in 1.5e8 fills (TDR table 5.1, pg 122)  
  // i.e 1100 >1.8 GeV events per fill (TDR page 122) (note this is higher than the 700 >1.8 GeV events per fill in (docdb 676)
  // x1.6 (TCut ? no flash) x 2.4 (E cut) =  4200 total events per fill, 180 total events per calo per fill (docdb 676)
 
  // divide by 24 for per calorimeter rate. 
  ne = ne / 24;

  printf("nsegments per calo %d, ne per fill per calo %d, nfills per flush %d, nflushes per run %d, flush-level threshold interval (GeV) %f (%f), threshold number %d\n", 
	 nsegs, ne, nfills, nflushes, threshold, threshold/GeVToADC, nthresholds);

  // define grid structure for run, flush, fill structure 
  nblocks1 = nfills / nthreads + 1;
  nblocks2 = ( nsegs * fill_buffer_max_length + nthreads - 1 )/ nthreads;
  nblocks3 = ( fill_buffer_max_length + nthreads - 1 )/ nthreads;
  nblocks4 = ( nsegs * nfills * fill_buffer_max_length + nthreads - 1 )/ nthreads;
  nblocks5 = ( nfills * fill_buffer_max_length + nthreads - 1 )/ nthreads;
  printf("per flush grid: nthreads %i, nblocks %i nthreads*nblocks %i\n", nthreads, nblocks1, nthreads*nblocks1 );
  printf("per bin grid: nthreads %i, nblocks %i nthreads*nblocks %i\n", nthreads, nblocks3, nthreads*nblocks3 );
  printf("per bin per segment grid: nthreads %i, nblocks %i nthreads*nblocks %i\n", nthreads, nblocks2, nthreads*nblocks2 );
  printf("per bin per fill grid: nthreads %i, nblocks %i nthreads*nblocks %i\n", nthreads, nblocks5, nthreads*nblocks5 );
  printf("per bin per segment per fill grid: nthreads %i, nblocks %i nthreads*nblocks %i\n", nthreads, nblocks4, nthreads*nblocks4 );

  // histogram binning
  printf("ns per fill %i, ns per bin %i, number of bins %d\n", nsPerFill, nsPerTick, fill_buffer_max_length);
  Char_t hname[256];
  for (int ih = 0; ih < nsegs; ih++) {

    for (int it = 0; it < nthresholds; it++) {

      //printf("hFlush1D: fill ih, it, ih + nthresholds*i) %i, %i, %i\n", ih, it, ih*nthresholds + it);

      sprintf( hname, "\n hFlush1D%02i_%02i", ih, it);
      hFlush1D[ih*nthresholds + it] = new TH1D( hname, hname, fill_buffer_max_length, 0.0, fill_buffer_max_length );
      sprintf( hname, "\n hPUFlush1D%02i_%02i", ih, it);
      hPUFlush1D[ih*nthresholds + it] = new TH1D( hname, hname, fill_buffer_max_length, 0.0, fill_buffer_max_length );
      sprintf( hname, "\n hLastFlush1D%02i_%02i", ih, it);
      hLastFlush1D[ih*nthresholds + it] = new TH1D( hname, hname, fill_buffer_max_length, 0.0, fill_buffer_max_length );
      sprintf( hname, "\n htmp%02i_%02i", ih, it);
      htmp[ih*nthresholds + it] = new TH1D( hname, hname, fill_buffer_max_length, 0.0, fill_buffer_max_length );
      sprintf( hname, "\n hNextLastFlush1D%02i_%02i", ih, it);
      hNextLastFlush1D[ih*nthresholds + it] = new TH1D( hname, hname, fill_buffer_max_length, 0.0, fill_buffer_max_length );
      sprintf( hname, "\n hStats1D%02i_%02i", ih, it);
      hStats1D[ih*nthresholds + it] = new TH1D( hname, hname, fill_buffer_max_length, 0.0, fill_buffer_max_length );
      sprintf( hname, "\n hFlush1Dlost%02i_%02i", ih, it);
      hFlush1Dlost[ih*nthresholds + it] = new TH1D( hname, hname, fill_buffer_max_length, 0.0, fill_buffer_max_length );
    }

    //sprintf( hname, "\n hFlush2D%02i", ih);
    //hFlush2D[ih] = new TH2D( hname, hname, fill_buffer_max_length, 0.0, fill_buffer_max_length, 64, -32, 31 );
    //sprintf( hname, "\n hFlush2DCoarse%02i", ih);
    //hFlush2DCoarse[ih] = new TH2D( hname, hname, fill_buffer_max_length, 0.0, fill_buffer_max_length, 256, 0, 8192 );
  }

  sprintf( hname, "\n hHits1D");
  hHits1D = new TH1D( hname, hname, fill_buffer_max_length, 0.0, fill_buffer_max_length );
  sprintf( hname, "\n hPUHits1D");
  hPUHits1D = new TH1D( hname, hname, fill_buffer_max_length, 0.0, fill_buffer_max_length );
  sprintf( hname, "\n hEnergy1D");
  hEnergy1D = new TH1D( hname, hname, energybins, 0.0, energybins );
  sprintf( hname, "\n hPUlostEnergy1D");
  hPUlostEnergy1D = new TH1D( hname, hname, energybins, 0.0, energybins );
  sprintf( hname, "\n hPUgainEnergy1D");
  hPUgainEnergy1D = new TH1D( hname, hname, energybins, 0.0, energybins );
  sprintf( hname, "\n hFlush2DSum");
  hFlush2DSum = new TH2D( hname, hname, fill_buffer_max_length, 0.0, fill_buffer_max_length, 64, -32, 31 );
  sprintf( hname, "\n hFlush2DCoarseSum");
  hFlush2DCoarseSum = new TH2D( hname, hname, fill_buffer_max_length, 0.0, fill_buffer_max_length, 256, 0, 8192 );


  // switch to do fill-by-fill noise
  bool fillbyfillnoise = false; 
  // switch to do flush-by-flush noise
  bool flushbyflushnoise = true; 

  // set device number for GPU
  int num_devices, device;
  cudaGetDeviceCount(&num_devices);
  if (num_devices > 1) {
     for (device = 0; device < num_devices; device++) {
  	 cudaDeviceProp properties;
	 cudaGetDeviceProperties(&properties, device);
         printf("device %d properties.multiProcessorCount %d\n", device, properties.multiProcessorCount);
     }			      
  }	      
  cudaSetDevice(0);

  // get some cuda device properties
  cudaDeviceProp prop;
  cudaGetDeviceProperties(&prop, 0);
  printf("Device Number: %d\n", 0);
  printf("Device name: %s\n", prop.name);
  printf("Memory Clock Rate (KHz): %d\n",
  		 prop.memoryClockRate);
  printf("Memory Bus Width (bits): %d\n",
                  prop.memoryBusWidth);


  // paramters for time measurements of GPU performance
  cudaEvent_t start, stop;
  float elapsedTime;
  cudaEventCreate(&start);
  cudaEventCreate(&stop);

  cudaEventRecord(start, 0);

  // device arrays for random number logic
  // could avoid the factor nfills in arrays by using atomicAdd() if only want flushed histograms?
  cudaMalloc( (void **)&d_state, nsegs*nfills*sizeof(curandState));
  cudaMalloc( (void **)&d_state2, nsegs*fill_buffer_max_length*sizeof(curandState));
  err = cudaThreadSynchronize();
  if ( cudaSuccess != err ) {
    printf("Cuda error in file '%s' in line %i : %s.\n",
             __FILE__, __LINE__, cudaGetErrorString( err) );
  }

  // host, device arrays for flushes
  //below are for flush-by-flush arrays  
  h_fillSumArray = (float *)malloc(nsegs*fill_buffer_max_length*sizeof(float));
  cudaMalloc( (void **)&d_fillSumArray, nsegs*fill_buffer_max_length*sizeof(float));
  h_hitSumArray = (float *)malloc(fill_buffer_max_length*sizeof(float));
  cudaMalloc( (void **)&d_hitSumArray, fill_buffer_max_length*sizeof(float));
  h_PUhitSumArray = (float *)malloc(fill_buffer_max_length*sizeof(float));
  cudaMalloc( (void **)&d_PUhitSumArray, fill_buffer_max_length*sizeof(float));
  h_energySumArray = (float *)malloc(energybins*sizeof(float));
  cudaMalloc( (void **)&d_energySumArray, energybins*sizeof(float));
  h_PUlostenergySumArray = (float *)malloc(energybins*sizeof(float));
  cudaMalloc( (void **)&d_PUlostenergySumArray, energybins*sizeof(float));
  h_PUgainenergySumArray = (float *)malloc(energybins*sizeof(float));
  cudaMalloc( (void **)&d_PUgainenergySumArray, energybins*sizeof(float));
  err = cudaThreadSynchronize();
  if ( cudaSuccess != err ) {
    printf("Cuda error in file '%s' in line %i : %s.\n",
             __FILE__, __LINE__, cudaGetErrorString( err) );
  }

  // measure time for array allocation
  cudaEventRecord(stop, 0);
  cudaEventSynchronize(stop);
  cudaEventElapsedTime(&elapsedTime, start, stop);
  printf(" ::: kernel malloc / cudaMalloc time %f ms\n",elapsedTime);

  // initialization for random number generator every 100 flushes
  cudaEventRecord(start, 0);

  init_rand<<<nblocks1,nthreads>>>( d_state, 0, time(NULL));
  init_rand<<<nblocks2,nthreads>>>( d_state2, 0, time(NULL));
  
  // measure time for random number initialization
  cudaEventRecord(stop, 0);
  cudaEventSynchronize(stop);
  cudaEventElapsedTime(&elapsedTime, start, stop);
  printf(" ::: kernel init_rand time %f ms\n",elapsedTime);


  struct timeval start_time, end_time;
  gettimeofday(&start_time, NULL);

  // variables for building the pile-up subtraction histogram
  double PUadd1, PUadd2, PUsub, PUcorr;

  // loop over flushes in ruhn
  for (int j = 0; j < nflushes; j++){

    printf("flush %i\n", j);


    // initialize to zero the arrays storing fill, hits and energy
    cudaEventRecord(start, 0);

    cudaMemset( d_fillSumArray, 0.0, nsegs*fill_buffer_max_length*sizeof(float));
    if ( err != cudaSuccess ) {
      printf("cudaMemset error!\n");
      return 1;
    }
    cudaMemset( d_hitSumArray, 0.0, fill_buffer_max_length*sizeof(float));
    if ( err != cudaSuccess ) {
      printf("cudaMemset error!\n");
      return 1;
    }
    cudaMemset( d_PUhitSumArray, 0.0, fill_buffer_max_length*sizeof(float));
    if ( err != cudaSuccess ) {
      printf("cudaMemset error!\n");
      return 1;
    }
    cudaMemset( d_energySumArray, 0.0, energybins*sizeof(float));
    if ( err != cudaSuccess ) {
      printf("cudaMemset error!\n");
      return 1;
    }
    cudaMemset( d_PUlostenergySumArray, 0.0, energybins*sizeof(float));
    if ( err != cudaSuccess ) {
      printf("cudaMemset error!\n");
      return 1;
    }
    cudaMemset( d_PUgainenergySumArray, 0.0, energybins*sizeof(float));
    if ( err != cudaSuccess ) {
      printf("cudaMemset error!\n");
      return 1;
    }

    cudaThreadSynchronize();

    // measure time for array initialization
    cudaEventRecord(stop, 0);
    cudaEventSynchronize(stop);
    cudaEventElapsedTime(&elapsedTime, start, stop);
    if (j == 0) printf(" ::: kernel initialize fillArray, hitArray, energyArray %f ms\n",elapsedTime);

    // make the fills within the flush
    cudaEventRecord(start, 0);
    make_randfill<<<nblocks1,nthreads>>>( d_state, d_hitArray, d_fillArray, d_hitSumArray, d_PUhitSumArray, d_fillSumArray, 
					  d_energySumArray, d_PUlostenergySumArray, d_PUgainenergySumArray, ne, fill_buffer_max_length, nfills, fillbyfillnoise);
    err=cudaGetLastError();
    if(err!=cudaSuccess) {
      printf("Cuda failure with user kernel function make)randfill %s:%d: '%s'\n",__FILE__,__LINE__,cudaGetErrorString(err));
      exit(0);
    } 

    // measure time for making flush
    cudaEventRecord(stop, 0);
    cudaEventSynchronize(stop);
    cudaEventElapsedTime(&elapsedTime, start, stop);
    if (j == 0) printf(" ::: kernel make_randfill time %f ms\n",elapsedTime);

    // make the fills within the flush
    cudaEventRecord(start, 0);
    add_flushnoise<<<nblocks2,nthreads>>>( d_state, d_fillSumArray, nfills, fill_buffer_max_length);
    err=cudaGetLastError();
    if(err!=cudaSuccess) {
      printf("Cuda failure with user kernel function add_flushnoise %s:%d: '%s'\n",__FILE__,__LINE__,cudaGetErrorString(err));
      exit(0);
    } 

    // measure time for add noise / pedestal to flush
    cudaEventRecord(stop, 0);
    cudaEventSynchronize(stop);
    cudaEventElapsedTime(&elapsedTime, start, stop);
    if (j == 0) printf(" ::: kernel add_flushnoise time %f ms\n",elapsedTime);

    // copy the flush from GPU to CPU
    cudaEventRecord(start, 0);
    cudaMemcpy( h_fillSumArray, d_fillSumArray, nsegs*fill_buffer_max_length*sizeof(float), cudaMemcpyDeviceToHost);
    err=cudaGetLastError();
    if(err!=cudaSuccess) {
      printf("Cuda failure %s:%d: '%s'\n",__FILE__,__LINE__,cudaGetErrorString(err));
      exit(0);
    }  
    cudaEventRecord(stop, 0);
    cudaEventSynchronize(stop);

    cudaEventRecord(start, 0);
    cudaMemcpy( h_hitSumArray, d_hitSumArray, fill_buffer_max_length*sizeof(float), cudaMemcpyDeviceToHost);
    err=cudaGetLastError();
    if(err!=cudaSuccess) {
      printf("Cuda failure %s:%d: '%s'\n",__FILE__,__LINE__,cudaGetErrorString(err));
      exit(0);
    }  
    cudaEventRecord(stop, 0);
    cudaEventSynchronize(stop);

    cudaEventRecord(start, 0);
    cudaMemcpy( h_PUhitSumArray, d_PUhitSumArray, fill_buffer_max_length*sizeof(float), cudaMemcpyDeviceToHost);
    err=cudaGetLastError();
    if(err!=cudaSuccess) {
      printf("Cuda failure %s:%d: '%s'\n",__FILE__,__LINE__,cudaGetErrorString(err));
      exit(0);
    }  
    cudaEventRecord(stop, 0);
    cudaEventSynchronize(stop);

    cudaEventRecord(start, 0);
    cudaMemcpy( h_energySumArray, d_energySumArray, energybins*sizeof(float), cudaMemcpyDeviceToHost);
    err=cudaGetLastError();
    if(err!=cudaSuccess) {
      printf("Cuda failure %s:%d: '%s'\n",__FILE__,__LINE__,cudaGetErrorString(err));
      exit(0);
    }  
    cudaEventRecord(stop, 0);
    cudaEventSynchronize(stop);

    cudaEventRecord(start, 0);
    cudaMemcpy( h_PUlostenergySumArray, d_PUlostenergySumArray, energybins*sizeof(float), cudaMemcpyDeviceToHost);
    err=cudaGetLastError();
    if(err!=cudaSuccess) {
      printf("Cuda failure %s:%d: '%s'\n",__FILE__,__LINE__,cudaGetErrorString(err));
      exit(0);
    }  
    cudaEventRecord(stop, 0);
    cudaEventSynchronize(stop);

    cudaEventRecord(start, 0);
    cudaMemcpy( h_PUgainenergySumArray, d_PUgainenergySumArray, energybins*sizeof(float), cudaMemcpyDeviceToHost);
    err=cudaGetLastError();
    if(err!=cudaSuccess) {
      printf("Cuda failure %s:%d: '%s'\n",__FILE__,__LINE__,cudaGetErrorString(err));
      exit(0);
    }  
    cudaEventRecord(stop, 0);
    cudaEventSynchronize(stop);

    // measure time for copying the flush from GPU to CPU
    cudaEventElapsedTime(&elapsedTime, start, stop);
    if (j == 0) printf(" ::: kernel cuda memcpy time for flush array ms\n",elapsedTime);
      
    // add flush to run root histograms
    for (int i = 0; i < nsegs*fill_buffer_max_length; i++){ // loop over xtals x samples
      
      int ih = i / fill_buffer_max_length; // xtal number
      int ib = i % fill_buffer_max_length; // sample number
      
      for (int it = 0; it < nthresholds; it++) { // loop over threshold values
	
	int kmin = 3, kmax = 3; // bookending parameters for rolling average calc
	double yaverage = 0.0, ysum = 0.0, ydiff = 0.0; // other paraters in rolling average calc
	if ( (ib >= kmin) && (ib <= fill_buffer_max_length-kmax-1) ) { // do bookending of histogramming that's needed for rolling average

	  // sum samples in rolling window of -kmin to +kmax around sample i and calc average  
	  for (unsigned int k = i-kmin; k <= i+kmax; k++) if ( k != i ) ysum += *(h_fillSumArray+k);                                      
	  yaverage = ysum / ( kmin + kmax );
	  
	  // difference of ith sample from rolling average
	  ydiff = *(h_fillSumArray+i) - yaverage;
	  
	  // make pileup correction histograms
	  
	  /* 
	     categories of curremt / prior fill hits
	     
	     1) if the only non-zero energy hit is current fill then PUSub = PUadd1 and PUadd2 = 0 and therefore no change 
	     in PU histogram contents as PUAdd1 is added then subtracted
	     
	     2) if the only non-zero energy hit is prior fill then PUSub = PUadd2 and PUadd1 = 0 and therefore no change 
	     in PU histogram contents as PUAdd2 is added then subtracted
	     
	     3) if  non-zero energy hits in current fill and prior fill then there is a change in the contents of the PU
	     histogram if one or both hits are below threshold and sum is above threshold (there's no change if both 
	     individual hits were above the threshold).
	     
	     the time dependent pedestal will break this algorithm . For current fill the time histogram is always filled 
	     if pedestal > threshold. For current+prior fill the PU time histogram is always filled if pedestal > threshold / 2.
	     
	  */

	  PUadd1 = ydiff;
	  if (j > 0) {
	    PUadd2 = hLastFlush1D[ih*nthresholds + it]->GetBinContent( ib+1 ); // get sample from previous flush at same fill time
	  } else {
            PUadd2 = 0.0; // dont get sample from previous fill for first flush
	  }
	  PUsub = PUadd1 + PUadd2;
          PUcorr = 0;
	  if (PUadd1 >= it*threshold) {
	    hPUFlush1D[ih*nthresholds + it]->AddBinContent( ib+1, PUadd1 );
            PUcorr += PUadd1;
	  } 

 	  if (PUadd2 >= it*threshold) {
	    hPUFlush1D[ih*nthresholds + it]->AddBinContent( ib+1, PUadd2 );
            PUcorr += PUadd2;
	  } 
	  if (PUsub  >= it*threshold) {
	    hPUFlush1D[ih*nthresholds + it]->AddBinContent( ib+1, -PUsub );
            PUcorr -= PUsub;
	  } 
	  /*
	  if (j> 0 && it == 1 && PUadd1 >= 1. && PUadd2 >= 1. ) { // not first flush, when pileup correction for it=1 threshold
	    printf("fill j %i, seg ih %i, thres %i, bin ib %i,  PUsub %f, PUadd1 (current) %f, PUadd2 (previous) %f, PU correction %f\n", 
	    j, ih, it, ib,  PUsub, PUadd1, PUadd2, PUcorr);
	  }
	  */

	  if (it > 0) {
	    if ( ydiff >= it*threshold) { // for above threshold pulses

	      hFlush1D[ih*nthresholds + it]->Fill( ib+1, ydiff); // fill the finite-threshold Q-method histogram
	      hStats1D[ih*nthresholds + it]->Fill( ib+1, 1); // fill the finite-threshold statistics histogram
	    } else {

	      hFlush1Dlost[ih*nthresholds + it]->Fill( ib+1, ydiff); // fill the below threshold histogram
	    }
	  } else { 

	    hFlush1D[ih*nthresholds + it]->Fill( ib+1, *(h_fillSumArray+i));  // special handling of zero-threshold histogram
	  } // it > 0, it = 0 procesing
 

	    // update  last, next-last flush histogram on last bin of bookended histogram ib-kmin 
	  if ( ib == fill_buffer_max_length-kmax-1 ) {
   
	    hNextLastFlush1D[ih*nthresholds + it]->Reset();
	    hNextLastFlush1D[ih*nthresholds + it]->Add( hLastFlush1D[ih*nthresholds + it], 1.0);
	    hLastFlush1D[ih*nthresholds + it]->Reset();
	    hLastFlush1D[ih*nthresholds + it]->Add( htmp[ih*nthresholds + it], 1.0);
            //if (it==1) printf("reset+fill last, next-last flush %i, ih %i, it %i, last integral %f, next last integral %f\n", 
	    //	   j, ih, it, hLastFlush1D[ih*nthresholds + it]->Integral(), hNextLastFlush1D[ih*nthresholds + it]->Integral() );
	  }

	  // update tmp histogram
	  if ( ib-kmin == 0 ) {
            //if (it==1) printf("before reset tmp %i, ih %i, it %i, last integral %f, next last integral %f\n",
	    //	   j, ih, it, htmp[ih*nthresholds + it]->Integral());
	    htmp[ih*nthresholds + it]->Reset();
            //if (it==0) printf("after reset tmp %i, ih %i, it %i, last integral %f, next last integral %f\n",
	    //	   j, ih, it, htmp[ih*nthresholds + it]->Integral());
	  }
	  if (it > 0) {

	    if ( ydiff >= it*threshold) { // for above threshold histograms

	      htmp[ih*nthresholds + it]->SetBinContent( ib+1, ydiff);
	      //if ( it == 1 ) printf("fill PU histogram, flush j %i, seg ih %i, thres %i, bin ib %i,  ydiff %f\n", j, ih, it, ib, ydiff);
	    } 
	  } else { // for zero threshold histogram

	      htmp[ih*nthresholds + it]->SetBinContent( ib+1, ydiff);
	  }
	  
	  //hFlush2D[ih]->Fill( ib+1, *(h_fillSumArray+i));
	  //hFlush2DCoarse[ih]->Fill( ib+1, *(h_fillSumArray+i));
	  //fprintf(fp, " %i %f\n", i+1, *(h_fillSumArray+i) );
	  
	} // book ending if statement
	
      } // loop over thresholds

    } // loop over array elements i = segments x samples
    
      // make xtal-summmed distributions
    for (int ib = 0; ib < fill_buffer_max_length; ib++){
      
      float sum = 0.0;
      for (int is = 0; is < nsegs; is++){
	sum += *(h_fillSumArray + is*fill_buffer_max_length + ib);
      }
      
      hFlush2DSum->Fill( ib+1, sum);
      hFlush2DCoarseSum->Fill( ib+1, sum);
    }
    
      // fill diagnostic hit distribution
      for (int ib = 0; ib < fill_buffer_max_length; ib++){
	hHits1D->Fill( ib+1, *(h_hitSumArray+ib));
      }
      
      // fill diagnostic hit distribution
      for (int ib = 0; ib < fill_buffer_max_length; ib++){
	hPUHits1D->Fill( ib+1, *(h_PUhitSumArray+ib));
      }
      
      // fill diagnostic energy distribution
      for (int ib = 0; ib < energybins; ib++){
	hEnergy1D->Fill( ib+1, *(h_energySumArray+ib));
      }
      
      // fill diagnostic PU energy distribution
      for (int ib = 0; ib < energybins; ib++){
	hPUlostEnergy1D->Fill( ib+1, *(h_PUlostenergySumArray+ib));
      }
      
      // fill diagnostic PU energy distribution
      for (int ib = 0; ib < energybins; ib++){
	hPUgainEnergy1D->Fill( ib+1, *(h_PUgainenergySumArray+ib));
      }

  } // loop over flushes
  
  // free device arrays
  cudaFree(d_state);
  cudaFree(d_state2);
  cudaFree(d_fillSumArray);
  cudaFree(d_hitSumArray);
  cudaFree(d_PUhitSumArray);
  cudaFree(d_energySumArray);
  cudaFree(d_PUlostenergySumArray);
  cudaFree(d_PUgainenergySumArray);

  // time elapsed for gnerating the entire run 
  gettimeofday(&end_time, NULL);
  printf("elapsed processing time, dt %f secs\n", toddiff(&end_time, &start_time));

  // open root file and write root hostograms
  Char_t fname[256];
  sprintf( fname, "root/threshold-qmethod-mimicT-thres%03i-ne%05i-nfill%05i-nflush%05i.root", (int)threshold, ne, nfills, nflushes);
  f = new TFile(fname,"recreate");
  printf("write histograms\n"); 

  for (int ih = 0; ih < nsegs; ih++) {
    printf("writing segment %i\n", ih);

    for (int it = 0; it < nthresholds; it++) {
      
      sprintf( hname, "h%02i_%02i", ih, it);
      f->WriteObject( hFlush1D[ih*nthresholds + it], hname);
      sprintf( hname, "hPU%02i_%02i", ih, it);
      f->WriteObject( hPUFlush1D[ih*nthresholds + it], hname);
      sprintf( hname, "hLastFlush%02i_%02i", ih, it);
      f->WriteObject( hLastFlush1D[ih*nthresholds + it], hname);
      sprintf( hname, "hNextLastFlush%02i_%02i", ih, it);
      f->WriteObject( hNextLastFlush1D[ih*nthresholds + it], hname);
      sprintf( hname, "hStats%02i_%02i", ih, it);
      f->WriteObject( hStats1D[ih*nthresholds + it], hname);
      sprintf( hname, "hlost%02i_%02i", ih, it);
      f->WriteObject( hFlush1Dlost[ih*nthresholds + it], hname);
    }

    //sprintf( hname, "s%02i", ih);
    //f->WriteObject( hFlush2D[ih], hname);
    //sprintf( hname, "sc%02i", ih);
    //f->WriteObject( hFlush2DCoarse[ih], hname);
  }

  sprintf( hname, "hHits");
  f->WriteObject( hHits1D, hname);
  sprintf( hname, "hPUHits");
  f->WriteObject( hPUHits1D, hname);
  sprintf( hname, "hEnergy");
  f->WriteObject( hEnergy1D, hname);
  sprintf( hname, "hPUlostEnergy");
  f->WriteObject( hPUlostEnergy1D, hname);
  sprintf( hname, "hPUgainEnergy");
  f->WriteObject( hPUgainEnergy1D, hname);
  sprintf( hname, "sSum");
  f->WriteObject( hFlush2DSum, hname);
  sprintf( hname, "scSum");
  f->WriteObject( hFlush2DCoarseSum, hname);
  f->Close();

  return 0;
}

