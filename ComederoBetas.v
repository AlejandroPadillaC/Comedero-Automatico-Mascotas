module Comedero_Inteligente(
    input wire clk_50mhz,       // Reloj principal de la FPGA (50 MHz)
    input wire sw_mode,         // Switch físico para alternar modos (0 = 1min/3p, 1 = 2min/2p)
    output wire scl,                     
    inout wire sda,             // 
    // Control del Motor Paso a Paso (Driver ULN2003)
    output reg [3:0] motor_out, // Salidas físicas (IN4, IN3, IN2, IN1)
    output wire led_minuto  // DEBUG: LED que cambia de estado cada minuto para asegurar que el I2C/RTC funciona    
);

    // =========================================================================
    // 1) Ritmo I2C Global (400 kHz)
    // =========================================================================
    reg [6:0] clk_cnt = 0; // Contador de 0 a 125
    wire tick_400k = (clk_cnt == 7'd124); // 50 MHz / 125 = 400 kHz // Booleano de 1 bit se cumple un ciclo de I2C
    always @(posedge clk_50mhz) begin
        if (tick_400k) clk_cnt <= 7'd0; //Volver a contar hasta 125 si ya se cumplio un ciclo, no se acumula solo es cada cuanto el tick
        else clk_cnt <= clk_cnt + 1'b1;
    end

    // =========================================================================
    // 2. ÁRBITRO DEL BUS I2C (Evita colisiones entre RTC y LCD)
    // =========================================================================
    reg [1:0] bus_state = 0; 
    reg rtc_req; 
    reg lcd_req; 

    always @(posedge clk_50mhz) begin
        if (tick_400k) begin
            case (bus_state)
                0: begin 
                    if (rtc_req) bus_state <= 1;
                    else if (lcd_req) bus_state <= 2;
                end
                1: begin 
                    if (!rtc_req) bus_state <= 0;
                end
                2: begin 
                    if (!lcd_req) bus_state <= 0;
                end
                default: bus_state <= 0;
            endcase
        end
    end

    reg scl_rtc_int = 1, scl_lcd_int = 1;
    reg rtc_sda_out = 1, lcd_sda_out = 1;
    reg rtc_sda_oe = 0,  lcd_sda_oe = 0;

    // FIX: Lógica estricta de Open-Drain para SCL
    wire scl_internal = (bus_state == 2'd1) ? scl_rtc_int :
                        (bus_state == 2'd2) ? scl_lcd_int : 1'b1;
    assign scl = (scl_internal == 1'b0) ? 1'b0 : 1'bz;

    wire sda_out = (bus_state == 2'd1) ? rtc_sda_out :
                   (bus_state == 2'd2) ? lcd_sda_out : 1'b1;
                   
    wire sda_oe  = (bus_state == 2'd1) ? rtc_sda_oe :
                   (bus_state == 2'd2) ? lcd_sda_oe : 1'b0;

    // FIX: Lógica estricta de Open-Drain para SDA
    assign sda = (sda_oe && sda_out == 1'b0) ? 1'b0 : 1'bz;
    wire sda_in = sda; 

    // =========================================================================
    // 2.5 VARIABLES GLOBALES DE ESTADO (Porciones)
    // =========================================================================
    reg [3:0] sum_cnt = 4'd0; 
    reg [3:0] pen_cnt = 4'd3; // Empieza con 3 por defecto
    reg refresh_req = 0, refresh_ack = 0;

    // =========================================================================
    // 3. LÓGICA DE CONTROL Y MUESTREO DEL RTC
    // =========================================================================
    reg [7:0] rtc_sec = 0, rtc_min = 0, rtc_hour = 0;
	 //
    reg [7:0] rtc_min_prev = 8'hFF; 
    reg is_first_read = 1'b1;
    reg rtc_motor_pulse = 1'b0; // Cuando la maquina evalua que ha pasado el tiempo y quedan porciones por dar La cambia cambia a 1 y afecta en el modulo 5
    
    // Variables para el modo alterno
    reg [3:0] min_elapsed = 4'd0; //Variable de cantidad de minutos que han pasado, contador
    reg sw_mode_rtc_prev = 1'b0; //
    
    reg led_toggle = 1'b0; // Comienza un led encendido que cuenta cuando pasa cada minuto 
    assign led_minuto = led_toggle; // Lo asigna a la salid del led 

    reg i2c_rtc_start = 0;
    wire i2c_rtc_busy; {
    reg [19:0] rtc_delay_cnt = 0; 
    
    reg [2:0] rtc_main_state = 0;
    localparam ST_BOOT        = 0, 
               ST_REQ_RTC     = 1, 
               ST_WAIT_RTC    = 2,
               ST_DELAY_READ  = 3, 
               ST_DELAY_CYCLE = 4;

    parameter D_READ_1MS    = 400;    
    parameter D_CYCLE_200MS = 80000;  

    always @(*) rtc_req = (rtc_main_state == ST_REQ_RTC) || (rtc_main_state == ST_WAIT_RTC) || (rtc_main_state == ST_DELAY_READ);

    always @(posedge clk_50mhz) begin
        if (tick_400k) begin
            i2c_rtc_start <= 1'b0; 
            rtc_motor_pulse <= 1'b0; 
            
            // Sincronización de reset de minutos al cambiar de modo
            sw_mode_rtc_prev <= sw_mode; //Si se cambia el modo por medio del switch 
            if (sw_mode != sw_mode_rtc_prev) begin
                min_elapsed <= 4'd0; //Resetea el contador de minutos pasados 
            end
            
            case (rtc_main_state)
                ST_BOOT: begin // Estado de espera para la FPGA con el modulo y comenzar la comunicacion I2C, solo cuando se enciende
                    if (rtc_delay_cnt >= 20000) begin 
                        rtc_delay_cnt <= 0; rtc_main_state <= ST_REQ_RTC;
                    end else rtc_delay_cnt <= rtc_delay_cnt + 1'b1;
                end
                ST_REQ_RTC: begin
                    if ((bus_state == 2'd1) && !i2c_rtc_busy && !i2c_rtc_start) begin
                        i2c_rtc_start <= 1'b1; //Comenzar comunicacion e implementacion I2C
                        rtc_main_state <= ST_WAIT_RTC; //Manda al estado de espera
                    end
                end
                ST_WAIT_RTC: begin  
                    if (!i2c_rtc_busy && !i2c_rtc_start) begin
                        rtc_delay_cnt <= 0; rtc_main_state <= ST_DELAY_READ; //Cambio de estado
                    end
                end
                ST_DELAY_READ: begin
                    if (rtc_delay_cnt >= D_READ_1MS) begin
                        rtc_delay_cnt <= 0; rtc_main_state <= ST_DELAY_CYCLE;
                        
                        if (rtc_min != rtc_min_prev) begin //Aca identifica si cambio de minuto o no del valor que se tenia en minuto previo 
                            if (!is_first_read) begin
                                
                                //Parpadeo del LED siempre vivo como testigo de vida del RTC
                                led_toggle <= ~led_toggle; 

                                if (sw_mode == 1'b0) begin
                                    // MODO 0: Dispara cada 1 minuto
                                    if (pen_cnt > 0) begin 
                                        rtc_motor_pulse <= 1'b1; 
                                    end
                                end 
										  else begin
                                    // MODO 1: Dispara cada 2 minutos
                                    if (min_elapsed >= 4'd1) begin //aca se controla la cantidad de tiempo de espera para el modo de minutos
                                        if (pen_cnt > 0) rtc_motor_pulse <= 1'b1;
                                        min_elapsed <= 4'd0; 
                                    end else begin
                                        min_elapsed <= min_elapsed + 1'b1;
                                    end
                                end
                            end
                            is_first_read <= 1'b0;
                            rtc_min_prev  <= rtc_min; //Da el valor del minuto nuevo como el estandar para el siguiente minuto
                        end
                    end else rtc_delay_cnt <= rtc_delay_cnt + 1'b1;
                end
                ST_DELAY_CYCLE: begin 
                    if (rtc_delay_cnt >= D_CYCLE_200MS) begin 
                        rtc_delay_cnt <= 0; rtc_main_state <= ST_REQ_RTC; 
                    end else rtc_delay_cnt <= rtc_delay_cnt + 1'b1;
                end
                default: rtc_main_state <= ST_BOOT;
            endcase
        end
    end

    // =========================================================================
    // 4. MÁQUINA I2C FÍSICA PARA EL RTC 
    // =========================================================================
    reg [2:0] i2c_rtc_state = 0;
    reg [2:0] rtc_bit_idx = 0;
    reg [1:0] rtc_phase = 0;
    
    assign i2c_rtc_busy = (i2c_rtc_state != 0 || i2c_rtc_start);
    reg [7:0] rtc_tx_byte, rtc_rx_byte;
    reg rtc_is_nack = 0;
    reg [4:0] rtc_seq_step = 0;

    always @(posedge clk_50mhz) begin
        if (tick_400k) begin
            case (i2c_rtc_state)
                0: begin 
                    rtc_sda_oe <= 1'b0; rtc_sda_out <= 1'b1; scl_rtc_int <= 1'b1;
                    if (i2c_rtc_start) begin i2c_rtc_state <= 1; rtc_seq_step <= 0; rtc_phase <= 0; end
                end
                1: begin 
                    rtc_phase <= rtc_phase + 1'b1;
                    if (rtc_phase == 0) begin rtc_sda_oe <= 1'b1; rtc_sda_out <= 1'b1; scl_rtc_int <= 1'b1; end
                    if (rtc_phase == 1) begin rtc_sda_out <= 1'b0; end 
                    if (rtc_phase == 2) begin scl_rtc_int <= 1'b0; end     
                    if (rtc_phase == 3) begin rtc_tx_byte <= 8'hD0; i2c_rtc_state <= 2; rtc_bit_idx <= 7; end
                end
                2: begin 
                    rtc_phase <= rtc_phase + 1'b1;
                    if (rtc_phase == 0) begin rtc_sda_out <= rtc_tx_byte[rtc_bit_idx]; scl_rtc_int <= 1'b0; rtc_sda_oe <= 1'b1; end
                    if (rtc_phase == 1) begin scl_rtc_int <= 1'b1; end
                    if (rtc_phase == 2) begin scl_rtc_int <= 1'b1; end
                    if (rtc_phase == 3) begin 
                        scl_rtc_int <= 1'b0;
                        if (rtc_bit_idx == 0) i2c_rtc_state <= 3;
                        else rtc_bit_idx <= rtc_bit_idx - 1'b1;
                    end
                end
                3: begin 
                    rtc_phase <= rtc_phase + 1'b1;
                    if (rtc_phase == 0) begin rtc_sda_oe <= 1'b0; scl_rtc_int <= 1'b0; end 
                    if (rtc_phase == 1) begin scl_rtc_int <= 1'b1; end
                    if (rtc_phase == 2) begin scl_rtc_int <= 1'b1; end
                    if (rtc_phase == 3) begin 
                        scl_rtc_int <= 1'b0; rtc_sda_oe <= 1'b1; 
                        if (rtc_seq_step == 0) begin rtc_tx_byte <= 8'h00; rtc_seq_step <= 1; i2c_rtc_state <= 2; rtc_bit_idx <= 7; end 
                        else if (rtc_seq_step == 1) begin i2c_rtc_state <= 7; rtc_phase <= 0; end 
                        else if (rtc_seq_step >= 2 && rtc_seq_step <= 4) begin i2c_rtc_state <= 4; rtc_bit_idx <= 7; end
                    end
                end
                4: begin 
                    rtc_phase <= rtc_phase + 1'b1;
                    if (rtc_phase == 0) begin rtc_sda_oe <= 1'b0; scl_rtc_int <= 1'b0; end 
                    if (rtc_phase == 1) begin scl_rtc_int <= 1'b1; end // FIX: Esperar en fase 1
                    if (rtc_phase == 2) begin scl_rtc_int <= 1'b1; rtc_rx_byte[rtc_bit_idx] <= sda_in; end // FIX: Leer en fase 2 estable
                    if (rtc_phase == 3) begin
                        scl_rtc_int <= 1'b0;
                        if (rtc_bit_idx == 0) begin
                            i2c_rtc_state <= 5; 
                            if (rtc_seq_step == 2)      rtc_sec  <= rtc_rx_byte;
                            else if (rtc_seq_step == 3) rtc_min  <= rtc_rx_byte;
                            else if (rtc_seq_step == 4) rtc_hour <= rtc_rx_byte;
                            rtc_is_nack <= (rtc_seq_step == 4); 
                        end else rtc_bit_idx <= rtc_bit_idx - 1'b1;
                    end
                end
                5: begin 
                    rtc_phase <= rtc_phase + 1'b1;
                    if (rtc_phase == 0) begin rtc_sda_out <= rtc_is_nack; rtc_sda_oe <= 1'b1; scl_rtc_int <= 1'b0; end 
                    if (rtc_phase == 1) begin scl_rtc_int <= 1'b1; end
                    if (rtc_phase == 2) begin scl_rtc_int <= 1'b1; end
                    if (rtc_phase == 3) begin
                        scl_rtc_int <= 1'b0;
                        if (rtc_seq_step == 4) i2c_rtc_state <= 6; 
                        else begin rtc_seq_step <= rtc_seq_step + 1'b1; i2c_rtc_state <= 4; rtc_bit_idx <= 7; end
                    end
                end
                6: begin 
                    rtc_phase <= rtc_phase + 1'b1;
                    if (rtc_phase == 0) begin rtc_sda_out <= 1'b0; scl_rtc_int <= 1'b0; rtc_sda_oe <= 1'b1; end
                    if (rtc_phase == 1) begin scl_rtc_int <= 1'b1; end
                    if (rtc_phase == 2) begin rtc_sda_out <= 1'b1; end 
                    if (rtc_phase == 3) begin i2c_rtc_state <= 0; rtc_sda_oe <= 1'b0; end 
                end
                7: begin 
                    rtc_phase <= rtc_phase + 1'b1;
                    if (rtc_phase == 0) begin rtc_sda_out <= 1'b1; scl_rtc_int <= 1'b0; rtc_sda_oe <= 1'b1; end 
                    if (rtc_phase == 1) begin scl_rtc_int <= 1'b1; end                                        
                    if (rtc_phase == 2) begin rtc_sda_out <= 1'b0; end                                        
                    if (rtc_phase == 3) begin 
                        scl_rtc_int <= 1'b0; rtc_tx_byte <= 8'hD1; rtc_bit_idx <= 7; rtc_seq_step <= 2; i2c_rtc_state <= 2; 
                    end
                end
            endcase
        end
    end

		// =========================================================================
		// 5. CONTROL DEL MOTOR PASO A PASO (OPTIMIZADO)
		// =========================================================================
		parameter DIVISOR   = 400000;  // Controla la velocidad de giro
		parameter MAX_PASOS = 1024;    
		reg        estado_motor = 0;   
		reg [18:0] contador_clk_motor = 0; //Contador para la velocidad, 1 tick cada 400k
		reg [12:0] contador_pasos = 0;  //Cantidad de pasos dados  
		reg [1:0]  indice_paso = 0; //Configuracion electromagnetica del motor  
		wire pulso_paso = (contador_clk_motor == (DIVISOR - 1)); 
		reg motor_done_pulse = 0;

		
		always @(posedge clk_50mhz) begin
			 motor_done_pulse <= 1'b0; 
			 case (estado_motor)
				  0: begin // Estado de apagado y espera de la señal de activacion Modulo 3
						contador_clk_motor <= 19'd0; 
						contador_pasos     <= 13'd0;
						if (rtc_motor_pulse) begin
							 estado_motor <= 1; // Si percibe el pulso en 1 cambia al estado de activacion y funcionamiento 
						end
				  end
				  1: begin // Estado de activacion y giro
						if (pulso_paso) begin //Comienza si se percibe que ya pasaron 400k ticks del reloj de la FPGA
							 contador_clk_motor <= 19'd0; 
							 indice_paso        <= indice_paso + 1'b1; //Literalmente da un paso y cambia el estado en la maquina de electromagnetissacion del motor
							 
							 if (contador_pasos >= (MAX_PASOS - 1)) begin //Revisa cuantos pasos ha dado el motor
								  estado_motor     <= 0; // Volver a estado 0 de reposo
								  motor_done_pulse <= 1'b1; // Avisar que terminó de suministrar toda la porcion
							 end else begin
								  contador_pasos <= contador_pasos + 1'b1; //Si no ha acabado de entregar, sigue acumulando pasos
							 end
						end else begin
							 contador_clk_motor <= contador_clk_motor + 1'b1; //sigue esperando a que se de el tick de pulso_paso
						end
				  end
				  default: estado_motor <= 0;
			 endcase
		end

		always @(*) begin
			 if (estado_motor == 1) begin // Encendido solo si está en Estado 1 (Giro)
				  case (indice_paso)
						2'b00: motor_out = 4'b1100; 
						2'b01: motor_out = 4'b0110; 
						2'b10: motor_out = 4'b0011; 
						2'b11: motor_out = 4'b1001; 
						default: motor_out = 4'b0000;
				  endcase
			 end else begin
				  motor_out = 4'b0000; // Motores apagados en reposo
			 end
		end
  // =========================================================================
    // 6. ACTUALIZACIÓN DINÁMICA DE VARIABLES PARA LCD Y SWITCH
    // =========================================================================
    reg sw_mode_prev = 1'b0; //Almacena el estado previo del SW
    reg [7:0] rtc_sec_prev_lcd = 8'hFF; //Variable 
    reg waiting_reset = 1'b0;
    reg [27:0] delay_5s_cnt = 28'd0;
    parameter WAIT_5_SEC = 250000000; // 50 MHz * 5 segundos

    always @(posedge clk_50mhz) begin
        sw_mode_prev <= sw_mode;
        rtc_sec_prev_lcd <= rtc_sec; // Muestreo para detectar cambio de segundo
        // 1. Limpieza de bandera de refresco de la LCD
        if (refresh_ack) refresh_req <= 1'b0;
        // 2. Refrescar LCD cada segundo para ver la hora moverse (Independiente del motor)
        if (rtc_sec != rtc_sec_prev_lcd) begin
            refresh_req <= 1'b1;
        end
        // 3. Lógica principal de Estado, Motor y Temporizador
        if (sw_mode != sw_mode_prev) begin
            // Se movió el switch: Reiniciamos la lógica de inmediato y cancelamos esperas
            sum_cnt <= 4'd0;
            if (sw_mode == 1'b1) pen_cnt <= 4'd2; // MODO 1: 2 porciones
            else                 pen_cnt <= 4'd3; // MODO 0: 3 porciones
            waiting_reset <= 1'b0; // Cancelar pausa si el usuario cambia de modo
            refresh_req <= 1'b1;
            
        end else if (motor_done_pulse) begin 
            // Ciclo normal cuando termina de girar el motor
            if (pen_cnt > 0) begin
                pen_cnt <= pen_cnt - 1'b1; // Descontar la porción
                sum_cnt <= sum_cnt + 1'b1; // Sumar al total
                refresh_req <= 1'b1; 
                
                // Si la porción que acabamos de restar nos dejó en 0, iniciamos la espera
                if (pen_cnt == 4'd1) begin 
                    waiting_reset <= 1'b1;
                    delay_5s_cnt <= 28'd0;
                end
            end
            
        end else if (waiting_reset) begin
            // Estamos en los 5 segundos de espera mostrando "P:0"
            if (delay_5s_cnt >= (WAIT_5_SEC - 1)) begin
                // Termina el tiempo: Reiniciamos TODO y salimos de la espera
                waiting_reset <= 1'b0;
                if (sw_mode == 1'b1) pen_cnt <= 4'd2;
                else                 pen_cnt <= 4'd3;
                sum_cnt <= 4'd0; // <--- AQUÍ ESTÁ LA CORRECCIÓN
                refresh_req <= 1'b1; // Refrescar LCD para mostrar los nuevos valores
            end else begin
                // Seguimos contando ciclos de reloj
                delay_5s_cnt <= delay_5s_cnt + 1'b1;
            end
        end
    end
    // =========================================================================
    // 7. MÁQUINA I2C FÍSICA PARA LA LCD 
    // =========================================================================
    reg [7:0] i2c_lcd_data;
    reg i2c_lcd_start = 0, i2c_lcd_ready = 1;
    reg [2:0] i2c_lcd_state = 0;
    reg [1:0] lcd_phase = 0;
    reg [2:0] lcd_bit_idx = 0; 
    
    wire [7:0] lcd_addr = 8'h4E; 

    always @(posedge clk_50mhz) begin
        if (tick_400k) begin
            case (i2c_lcd_state)
                0: begin 
                    lcd_sda_oe <= 1'b0; lcd_sda_out <= 1'b1; scl_lcd_int <= 1'b1; i2c_lcd_ready <= 1'b1;
                    if (i2c_lcd_start) begin i2c_lcd_state <= 1; lcd_phase <= 2'd0; i2c_lcd_ready <= 1'b0; end
                end
                1: begin 
                    lcd_phase <= lcd_phase + 1'b1;
                    if (lcd_phase == 0) begin lcd_sda_oe <= 1'b1; lcd_sda_out <= 1'b1; scl_lcd_int <= 1'b1; end
                    if (lcd_phase == 1) begin lcd_sda_out <= 1'b0; end
                    if (lcd_phase == 2) begin scl_lcd_int <= 1'b0; end
                    if (lcd_phase == 3) begin lcd_bit_idx <= 3'd7; i2c_lcd_state <= 2; end
                end
                2: begin 
                    lcd_phase <= lcd_phase + 1'b1;
                    if (lcd_phase == 0) begin lcd_sda_out <= lcd_addr[lcd_bit_idx]; scl_lcd_int <= 1'b0; end
                    if (lcd_phase == 1) begin scl_lcd_int <= 1'b1; end
                    if (lcd_phase == 2) begin scl_lcd_int <= 1'b1; end
                    if (lcd_phase == 3) begin 
                        scl_lcd_int <= 1'b0; 
                        if (lcd_bit_idx == 0) i2c_lcd_state <= 3; else lcd_bit_idx <= lcd_bit_idx - 1'b1;
                    end
                end
                3: begin 
                    lcd_phase <= lcd_phase + 1'b1;
                    if (lcd_phase == 0) begin lcd_sda_oe <= 1'b0; scl_lcd_int <= 1'b0; end
                    if (lcd_phase == 1) begin scl_lcd_int <= 1'b1; end
                    if (lcd_phase == 2) begin scl_lcd_int <= 1'b1; end
                    if (lcd_phase == 3) begin scl_lcd_int <= 1'b0; lcd_sda_oe <= 1'b1; lcd_bit_idx <= 3'd7; i2c_lcd_state <= 4; end
                end
                4: begin 
                    lcd_phase <= lcd_phase + 1'b1;
                    if (lcd_phase == 0) begin lcd_sda_out <= i2c_lcd_data[lcd_bit_idx]; scl_lcd_int <= 1'b0; end
                    if (lcd_phase == 1) begin scl_lcd_int <= 1'b1; end
                    if (lcd_phase == 2) begin scl_lcd_int <= 1'b1; end
                    if (lcd_phase == 3) begin 
                        scl_lcd_int <= 1'b0;
                        if (lcd_bit_idx == 0) i2c_lcd_state <= 5; else lcd_bit_idx <= lcd_bit_idx - 1'b1;
                    end
                end
                5: begin 
                    lcd_phase <= lcd_phase + 1'b1;
                    if (lcd_phase == 0) begin lcd_sda_oe <= 1'b0; scl_lcd_int <= 1'b0; end
                    if (lcd_phase == 1) begin scl_lcd_int <= 1'b1; end
                    if (lcd_phase == 2) begin scl_lcd_int <= 1'b1; end
                    if (lcd_phase == 3) begin scl_lcd_int <= 1'b0; lcd_sda_oe <= 1'b1; lcd_sda_out <= 1'b0; i2c_lcd_state <= 6; end
                end
                6: begin 
                    lcd_phase <= lcd_phase + 1'b1;
                    if (lcd_phase == 0) begin lcd_sda_out <= 1'b0; scl_lcd_int <= 1'b0; end
                    if (lcd_phase == 1) begin scl_lcd_int <= 1'b1; end
                    if (lcd_phase == 2) begin lcd_sda_out <= 1'b1; end
                    if (lcd_phase == 3) begin i2c_lcd_state <= 0; lcd_sda_oe <= 1'b0; end
                end
            endcase
        end
    end

    // =========================================================================
    // 8. SECUENCIADOR Y GESTIÓN DE LA LCD
    // =========================================================================
    reg [3:0] lcd_state = 0;
    reg [15:0] lcd_delay_cnt = 0;
    reg [5:0] cmd_idx = 0; 
    reg [8:0] current_word;

    always @(*) lcd_req = (lcd_state != 0) && (lcd_state != 11);

    always @(*) begin
        case(cmd_idx)
            // INICIALIZACIÓN BÁSICA DE LA LCD
            0: current_word = {1'b0, 8'h33}; 1: current_word = {1'b0, 8'h32}; 2: current_word = {1'b0, 8'h28}; 
            3: current_word = {1'b0, 8'h0C}; 4: current_word = {1'b0, 8'h06}; 5: current_word = {1'b0, 8'h01}; 
            
            // FILA 1: "Hora: HH:MM:SS  "
            6: current_word = {1'b0, 8'h80}; // Poner el cursor al inicio de la primera fila
            7: current_word = {1'b1, 8'h48}; // 'H'
            8: current_word = {1'b1, 8'h6F}; // 'o'
            9: current_word = {1'b1, 8'h72}; // 'r'
            10: current_word = {1'b1, 8'h61}; // 'a'
            11: current_word = {1'b1, 8'h3A}; // ':'
            12: current_word = {1'b1, 8'h20}; // ' '
            // Extracción de decenas y unidades BCD del RTC (se suma 8'h30 para convertir a ASCII)
            13: current_word = {1'b1, 8'h30 + {2'b00, rtc_hour[5:4]}}; // HH (Decenas)
            14: current_word = {1'b1, 8'h30 + rtc_hour[3:0]};          // HH (Unidades)
            15: current_word = {1'b1, 8'h3A}; // ':'
            16: current_word = {1'b1, 8'h30 + {1'b0, rtc_min[6:4]}};   // MM (Decenas)
            17: current_word = {1'b1, 8'h30 + rtc_min[3:0]};           // MM (Unidades)
            18: current_word = {1'b1, 8'h3A}; // ':'
            19: current_word = {1'b1, 8'h30 + {1'b0, rtc_sec[6:4]}};   // SS (Decenas)
            20: current_word = {1'b1, 8'h30 + rtc_sec[3:0]};           // SS (Unidades)
            21: current_word = {1'b1, 8'h20}; // ' '
            22: current_word = {1'b1, 8'h20}; // ' '
            
            // FILA 2: "P:X    Total:Y  "
            23: current_word = {1'b0, 8'hC0}; // Poner el cursor al inicio de la segunda fila
            24: current_word = {1'b1, 8'h50}; // 'P'
            25: current_word = {1'b1, 8'h3A}; // ':'
            26: current_word = {1'b1, 8'h30 + pen_cnt}; // Variable porciones pendientes
            27: current_word = {1'b1, 8'h20}; // ' '
            28: current_word = {1'b1, 8'h20}; // ' '
            29: current_word = {1'b1, 8'h20}; // ' '
            30: current_word = {1'b1, 8'h20}; // ' '
            31: current_word = {1'b1, 8'h54}; // 'T'
            32: current_word = {1'b1, 8'h6F}; // 'o'
            33: current_word = {1'b1, 8'h74}; // 't'
            34: current_word = {1'b1, 8'h61}; // 'a'
            35: current_word = {1'b1, 8'h6C}; // 'l'
            36: current_word = {1'b1, 8'h3A}; // ':'
            37: current_word = {1'b1, 8'h30 + sum_cnt}; // Variable porciones totales
            38: current_word = {1'b1, 8'h20}; // ' '
            39: current_word = {1'b1, 8'h20}; // ' '
            default: current_word = {1'b0, 8'h00};
        endcase
    end

    wire rs_bit = current_word[8];
    wire [7:0] d_byte = current_word[7:0];

    always @(posedge clk_50mhz) begin
        if (tick_400k) begin
            case (lcd_state)
                0: begin 
                    if (lcd_delay_cnt >= 20000) begin lcd_delay_cnt <= 0; lcd_state <= 1; end
                    else lcd_delay_cnt <= lcd_delay_cnt + 1'b1;
                end
                1: begin 
                    if (bus_state == 2'd2) begin
                        if (cmd_idx == 6'd40) lcd_state <= 11;
                        else lcd_state <= 2;
                    end
                end
                2: begin 
                    if (i2c_lcd_ready) begin
                        i2c_lcd_data  <= (d_byte & 8'hF0) | (rs_bit ? 4'hD : 4'hC);
                        i2c_lcd_start <= 1'b1; lcd_state <= 3;
                    end
                end
                3: begin i2c_lcd_start <= 1'b0; if (i2c_lcd_ready) lcd_state <= 4; end
                4: begin 
                    if (i2c_lcd_ready) begin
                        i2c_lcd_data  <= (d_byte & 8'hF0) | (rs_bit ? 4'h9 : 4'h8);
                        i2c_lcd_start <= 1'b1; lcd_state <= 5;
                    end
                end
                5: begin i2c_lcd_start <= 1'b0; if (i2c_lcd_ready) lcd_state <= 6; end
                6: begin 
                    if (i2c_lcd_ready) begin
                        i2c_lcd_data  <= ((d_byte << 4) & 8'hF0) | (rs_bit ? 4'hD : 4'hC);
                        i2c_lcd_start <= 1'b1; lcd_state <= 7;
                    end
                end
                7: begin i2c_lcd_start <= 1'b0; if (i2c_lcd_ready) lcd_state <= 8; end
                8: begin 
                    if (i2c_lcd_ready) begin
                        i2c_lcd_data  <= ((d_byte << 4) & 8'hF0) | (rs_bit ? 4'h9 : 4'h8);
                        i2c_lcd_start <= 1'b1; lcd_state <= 9;
                    end
                end
                9: begin i2c_lcd_start <= 1'b0; if (i2c_lcd_ready) begin lcd_delay_cnt <= 0; lcd_state <= 10; end end
                10: begin 
                    if (lcd_delay_cnt >= 800) begin
                        lcd_delay_cnt <= 0; cmd_idx <= cmd_idx + 1'b1; lcd_state <= 1;
                    end else lcd_delay_cnt <= lcd_delay_cnt + 1'b1;
                end
                11: begin 
                    i2c_lcd_start <= 1'b0;
                    if (refresh_req) begin
                        cmd_idx <= 6'd6; lcd_state <= 1; refresh_ack <= 1'b1;
                    end else refresh_ack <= 1'b0;
                end
            endcase
        end
    end

endmodule