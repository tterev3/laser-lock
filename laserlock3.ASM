;laser safety lock controller version 2
;version 2 implements configurable unlock code by function calls
;pic is connected to laser's battery, an led, and a momentary switch
;pic outputs to a p-channel mosfet which feeds the laser diode driver from the battery

;the unlock sequence is press click click press (press is >1/2s, click is <1/4s)

;version 3 implements smarter response to incorrect code inputs - sets a flag and waits until inputs
;stop before showing accept/reject so that the code can't be guessed

	list      p=10f206           ; list directive to define processor
	#include <p10f206.inc>        ; processor specific variable definitions

	errorlevel  -302              ; suppress message 302 from list file

	__CONFIG   _CP_OFF & _MCLRE_OFF & _WDT_OFF & _IntRC_OSC


#define	led		GPIO,0
;#define	output	GPIO,1		;
#define	laser	GPIO,2		;
#define	switch	GPIO,3



;***** VARIABLE DEFINITIONS 0x08 through 0x1F

switchcount	equ	0x08
temp		equ	0x09
locktimer	equ	0x0a
blinktimer	equ	0x0b
flags		equ	0x0c
delayer1				EQU		0X0d
delayer2				EQU		0X0e
runtimerlo				EQU		0x0f		
runtimerhi				EQU		0x10
switchstate				EQU		0x11		
presstimer				EQU		0x12		
bright					EQU		0x13		
fadecounter				equ		0x14
pwmcounter				equ		0x15
fadeslow				equ		0x16
;oncolor					equ		0x17

#define	clickflag	flags,0		;if this flag is set, the press was short enough to register as a click
#define	switchflag	flags,1		
#define	accept		flags,3

;presets
locktime	equ		.180	;number of 2hz led toggles to shutdown for inactivity
blinktime1	equ		.50		;number of 10ms loops before an led toggle in armed mode (1hz blink)
blinktime2	equ		.6		;number of 10ms loops before an led toggle in firing mode (8hz blink)
runtimelo	equ		.60
runtimehi	equ		.16		;product of these divided by 8Hz gives the auto-off time in constant mode
presstime	equ		.40		;number of 10ms cycles for a press (1/2s)
toolong		equ		.180-presstime	;number of 10ms cycles for a press to be rejected (too long) (after presstime)(2s)
interclick	equ		.50		;number of 10ms cycles between clicks (1/2s)
presstime2	equ		.30		;time x10ms to register as a click in armed mode (for continuous operation)

;**********************************************************************
		ORG     0x000             ; processor reset vector
configure
	movwf   OSCCAL            ; update register with factory cal value 

	movlw	b'00000111'
	OPTION				;GP wake up on, pullups on, TMR0 on PCL, prescale TMR0 1:256

	movlw	b'00000000'
	movwf	GPIO		;set outputs (led and laser off)

	movlw	b'11111010'	;GP0 and GP2 output
	TRIS	GPIO

	movlw	b'01110111'
	movwf	CMCON0		;comparator off

	goto	programstart
	

;==============subroutines==================

delay					;delays for approximately (WREG) in milliseconds 
	movwf	delayer2	
	clrf	delayer1
delayloop1
	nop
	decfsz	delayer1,f
	goto	delayloop1
	movlw	.248
	movwf	delayer1
	decfsz	delayer2,f
	goto	delayloop1
	retlw	.0

getswitch				;reads the state of the switch with 10 similar samples for debouncing
	movlw	.10
	movwf	switchcount
	clrf	switchstate
	ifset	switch
	bsf		switchstate,3
gsloop					;this loops implements its own 1ms delay to avoid stack overflow 
	clrf	delayer1
gsdelay
	nop
	decfsz	delayer1,f
	goto	gsdelay		;keep waiting for 1ms
	movfw	GPIO
	andlw	b'00001000'	;mask out just the switch
	xorwf	switchstate,w	;compare with the original
	ifzero				;if there is no change
	goto	$+2			;jump ahead
	goto	getswitch	;else, the state changed, start over
	decfsz	switchcount,f
	goto	gsloop		;get 9 more sucessful readings
	bsf		switchflag
	ifclr	switchstate,3
	bcf		switchflag
	retlw	.0			;return the state of the switch in switchflag

fader				;does the 'unlocked' display
	clrf	bright
	clrf	fadecounter
	clrf	pwmcounter
	movlw	.30
	movwf	fadeslow
fadeloop1
	bsf		led
	movfw	fadecounter
	call	fadetable
	movwf	bright
fadeloop2
	decfsz	bright,f
	goto	$+2
	bcf		led
	decfsz	pwmcounter,f
	goto	fadeloop2
	decfsz	fadeslow,f
	goto	fadeloop1
	movlw	.30
	movwf	fadeslow
	incf	fadecounter,f
	movlw	.25
	subwf	fadecounter,w
	ifzero
	retlw	.0
	goto	fadeloop1

fadetable
	addwf	PCL,f
	retlw .1	; 0
	retlw .1	; 1
	retlw .2	; 2
	retlw .4	; 3
	retlw .7	; 4
	retlw .10	; 5
	retlw .15	; 6
	retlw .20	; 7
	retlw .26	; 8
	retlw .33	; 9
	retlw .41	; 10
	retlw .49	; 11
	retlw .59	; 12
	retlw .69	; 13
	retlw .80	; 14
	retlw .92	; 15
	retlw .104	; 16
	retlw .118	; 17
	retlw .132	; 18
	retlw .147	; 19
	retlw .163	; 20
	retlw .180	; 21
	retlw .197	; 22
	retlw .216	; 23
	retlw .235	; 24
	retlw .255	; 25
	retlw .255	; 26

press						;called after switch goes down. returns if it's a good press. otherwise jumps to badseq
	movlw	presstime
	movwf	presstimer		;load press time
sq1
	call	getswitch
	ifset	switchflag		;if the switch comes up too early
	goto	badseq		;go reject the sequence
	decfsz	presstimer,f	;wait out the 1/2 second
	goto	sq1
	movlw	toolong
	movwf	presstimer
sq2
	call	getswitch		;this will take 10ms nominally
	ifset	switchflag		;if the switch is released
	goto	sq3				;go to the next thing in the sequence
	decfsz	presstimer,f
	goto	sq2				;hold here for up to the toolong time
	goto	badseq		;held too long, reject
sq3							;good first press detected (and release has been debounced)
	bcf		led
	retlw	.0

click						;called after switch goes down. returns if it's a good press. otherwise jumps to badseq
	movlw	presstime
	movwf	presstimer
sq6
	call	getswitch
	ifset	switchflag		;if the switch has been released in time
	goto	sq7				;go to next step
	decfsz	presstimer,f
	goto	sq6
	goto	badseq		;held too long
sq7							;click & release sucessful
	bcf		led
	retlw	.0

badseq
	bcf		accept
	retlw	.0

between						;called after switch comes up. returns if the switch goes down within interclick time. otherwise jumps to badseq
	movlw	interclick
	movwf	presstimer
sq4
	call	getswitch
	ifclr	switchflag		;if the switch has been pressed again
	goto	sq5				;go to the next step
	decfsz	presstimer,f	
	goto	sq4				;hold here for up to 1/2s
	goto	badsequence		;too long between clicks, reject
sq5
	bsf		led
	retlw	.0

;==================initialization==============
programstart
	clrf	flags

	call	getswitch

	ifset	STATUS,GPWUF	;if this was due to a pin change,
	goto	sequencetest	;go read in the unlock sequence
	bsf		led				;else, this was a power-up, blink the led
	clrw
	call	delay
	call	delay			;1/2 second on time
	goto	shutdown		;shutdown (this will turn the led off)
sequencetest				;wake due to pin change, watch for the unlock sequence
	call	getswitch
	ifset	switchflag		;if we woke up due to GPWUF but the switch is up, it was a malfunction
	goto	shutdown		;now we know the switch is definitely down
	bsf		led				;led will mirror the actions on the switch

	bsf		accept

	call	click
	call	between
	call	press
	call	between
	call	click
	call	between
	call	click

	ifclr	accept
	goto	badsequence

	call	fader			;go do the 'unlocked' display
laserarmed					;we are armed! set up the inactivity timer
	movlw	locktime
	movwf	locktimer
	movlw	blinktime1
	movwf	blinktimer
	call	getswitch
	ifclr	switchflag
	goto	$-2				;hold until switch is released
armedloop
	decfsz	blinktimer,f
	goto	armedswitchtest	;not zero, continue as normal
	movfw	GPIO			;blink timer was zero, so
	xorlw	b'00000001'
	movwf	GPIO			;toggle the led
	movlw	blinktime1
	movwf	blinktimer		;reload the timer
	decfsz	locktimer,f		;decrement the lockout timer
	goto	armedswitchtest	;not zero, continue as normal
	goto	shutdown		;inactivity timer ran out, shut down
armedswitchtest
	call	getswitch
	ifset	switchflag
	goto	armedloop		;if the switch is up, keep waiting here

	bsf		laser			;switch down, FIRE!
	movlw	presstime2
	movwf	presstimer
	movlw	blinktime2
	movwf	blinktimer
	bsf		clickflag
clickloop
	call	getswitch
	ifset	switchflag		;if switch has been released
	goto	clicktest		;go take action
	decfsz	presstimer,f	;count down press time
	goto	$+2				;normally jump ahead
	bcf		clickflag		;if press time was too long, clear the click flag
	decfsz	blinktimer,f
	goto	clickloop		;not zero, continue looping
	movfw	GPIO			;blink timer was zero, so
	xorlw	b'00000001'
	movwf	GPIO			;toggle the led
	movlw	blinktime2
	movwf	blinktimer		;reload the blink timer
	goto	clickloop		;stay in the loop
clicktest					;switch was released
	ifset	clickflag		;if the click flag was still set
	goto	constantmodestart	;go start running in constant mode
	bcf		laser			;else we were running in momentary. laser off
	movlw	.10
	call	delay			;delay to ensure clean shutdown
	goto	laserarmed		;go back to armed mode
constantmodestart			;a click was detected while armed, run constant
	movlw	runtimehi
	movwf	runtimerhi
	movlw	runtimelo
	movwf	runtimerlo		;load the auto-off timer bytes
	movlw	blinktime2
	movwf	blinktimer		;set up for fast blink
constantloop
	call	getswitch
	ifclr	switchflag		;if the switch was pressed again
	goto	constantend		;end running in constant mode
	decfsz	blinktimer,f
	goto	constantloop	;blink timer not zero, keep looping
	movfw	GPIO			;blink timer was zero, so
	xorlw	b'00000001'
	movwf	GPIO			;toggle the led
	movlw	blinktime2
	movwf	blinktimer		;reload the blink timer
	decfsz	runtimerlo,f	;decrement the auto-off timer low byte
	goto	constantloop	;timer didn't run out
	movlw	runtimelo
	movwf	runtimerlo		;timer did run out, reload it
	decfsz	runtimerhi,f	;decrement timer high byte
	goto	constantloop
	bcf		laser
	movlw	.10
	call	delay
	goto	shutdown		;timer ran out, shut down

constantend
	bcf		laser
	bsf		led
	call	getswitch
	ifclr	switchflag		;wait until switch is released
	goto	$-2
	movlw	.10
	call	delay
	goto	laserarmed		;go back to armed mode

badsequence
	movlw	.6
	movwf	blinktimer
bsloop
	movfw	GPIO
	xorlw	b'00000001'
	movwf	GPIO			;toggle led
	movlw	.125
	call	delay
	decfsz	blinktimer,f
	goto	bsloop
	goto	shutdown	

shutdown
	movlw	b'00000000'
	movwf	GPIO		;set outputs (led and laser off)
	movlw	.5	
	call	delay
	movlw	b'11111000'	;ensure switch is input
	TRIS	GPIO
	movlw	b'00000111'
	OPTION	;pullups on, TMR0 on PCL, prescale TMR0 1:256
	movlw	b'01110111'
	movwf	CMCON0		;comparator off
	movfw	GPIO		;read port to save state
	sleep				;a return of power will change the i/o port and cause a reset


		END                       ; directive 'end of program'

