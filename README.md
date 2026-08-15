# Comedero-Automatico-Mascotas

# 🐾 FPGA Automated Pet Feeder (Verilog & FSM)

![Verilog](https://img.shields.io/badge/HDL-Verilog-blue.svg)
![FPGA](https://img.shields.io/badge/Hardware-FPGA-orange.svg)
![Protocol](https://img.shields.io/badge/Protocol-I2C-green.svg)
![License](https://img.shields.io/badge/License-MIT-brightgreen.svg)

---

## 1. Descripción y Justificación del Proyecto

### Descripción
Este proyecto consiste en el diseño e implementación de un **comedero automático para mascotas** desarrollado en su totalidad en **Verilog HDL** para su despliegue en tarjetas FPGA. El sistema gestiona ciclos de alimentación programados, control de actuadores (servomotor o motor paso a paso) y comunicación serial sincrónica con periféricos mediante el protocolo **I2C**, todo procesado directamente a nivel de hardware lógico reconfigurable sin depender de un procesador embebido (*soft-core*) ni microcontroladores externos.

### Justificación
Frente a las soluciones tradicionales basadas en microcontroladores y software secuencial (como Arduino o ESP32), la implementación de este sistema directamente en una FPGA aporta ventajas críticas:
* **Paralelismo Real y Determinismo:** Manejo simultáneo e independiente del generador de pulsos PWM, la lectura continua del bus I2C y la temporización general sin latencias por interrupciones.
* **Fiabilidad Físicamente Robusta:** La arquitectura basada en Máquinas de Estado Finito (FSM) sintetizadas en bloques lógicos elimina riesgos de bloqueos de software (*crashes*) o problemas de gestión de memoria.
* **Diseño Digital Puro:** Demuestra la integración de conceptos avanzados de lógica digital, tales como controladores I2C personalizados a nivel de bit, divisores de frecuencia hardware y máquinas de estado acopladas.

---

## 2. Módulos y Componentes del Proyecto

### Componentes de Hardware

| Componente | Modelo / Tipo | Función en el Sistema |
| :--- | :--- | :--- |
| **Tarjeta FPGA** | Cyclone IV / Basys 3 / Nexys | Procesamiento de la lógica RTL y generación de señales de control. |
| **Módulo RTC / Sensor** | DS3231 (I2C) / Sensor de Peso | Provee la hora en tiempo real o la masa de alimento en el plato vía I2C. |
| **Actuador** | Servomotor SG90 / Motor Paso a Paso | Apertura y cierre del mecanismo dispensador de croquetas. |
| **Interfaz de Usuario** | Displays 7 Segmentos / LEDs / Botones | Configuración de raciones, estado de la FSM e indicadores de error. |
| **Alimentación** | Fuente Regulada Externa (5V/12V) | Suministro independiente para los motores y desacople de ruido eléctrico. |

### Jerarquía de Módulos Verilog

```text
top_pet_feeder/
├── clock_divider.v        # Divisor de frecuencia para I2C y PWM
├── i2c_master.v           # Controlador maestro de protocolo I2C
├── fsm_main_controller.v  # Máquina de estados principal del comedero
├── pwm_driver.v           # Controlador PWM para el movimiento del motor
└── display_driver.v       # Decodificador para la interfaz visual
