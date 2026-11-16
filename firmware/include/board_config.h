#pragma once

#if defined(TARGET_CYD)

#include <LovyanGFX.hpp>

#define SCREEN_WIDTH        320
#define SCREEN_HEIGHT       240
#define VIEWPORT_OFFSET_X   40
#define VIEWPORT_OFFSET_Y   0
#define ENABLE_DEBUG_STRIP  1

class LGFX : public lgfx::LGFX_Device {
    lgfx::Panel_ST7789  _panel_instance;
    lgfx::Bus_SPI       _bus_instance;
    lgfx::Light_PWM     _light_instance;
    lgfx::Touch_XPT2046 _touch_instance;

public:
    LGFX(void) {
        // Display SPI Bus (HSPI / SPI2)
        {
            auto cfg = _bus_instance.config();
            cfg.spi_host   = HSPI_HOST;
            cfg.spi_mode   = 0;
            cfg.freq_write = 40000000;
            cfg.freq_read  = 16000000;
            cfg.spi_3wire  = false;
            cfg.use_lock   = true;
            cfg.dma_channel = SPI_DMA_CH_AUTO;
            cfg.pin_sclk   = 14;
            cfg.pin_mosi   = 13;
            cfg.pin_miso   = 12;
            cfg.pin_dc     = 2;
            _bus_instance.config(cfg);
            _panel_instance.setBus(&_bus_instance);
        }
        // ST7789 240x320 Panel (CYD Single USB-C ESP32-WROOM-32E)
        {
            auto cfg = _panel_instance.config();
            cfg.pin_cs           = 15;
            cfg.pin_rst          = -1;
            cfg.pin_busy         = -1;
            cfg.memory_width     = 240;
            cfg.memory_height    = 320;
            cfg.panel_width      = 240;
            cfg.panel_height     = 320;
            cfg.offset_x         = 0;
            cfg.offset_y         = 0;
            cfg.offset_rotation  = 0;
            cfg.readable         = true;
            cfg.invert           = true;  // ST7789 CYD variants require display color inversion
            cfg.rgb_order        = false;
            cfg.dlen_16bit       = false;
            cfg.bus_shared       = true;
            _panel_instance.config(cfg);
        }
        // Backlight PWM on GPIO 21
        {
            auto cfg = _light_instance.config();
            cfg.pin_bl      = 21;
            cfg.invert      = false;
            cfg.freq        = 44100;
            cfg.pwm_channel = 7;
            _light_instance.config(cfg);
            _panel_instance.setLight(&_light_instance);
        }
        // Resistive Touch XPT2046 on dedicated software SPI
        {
            auto cfg = _touch_instance.config();
            cfg.x_min      = 300;
            cfg.x_max      = 3900;
            cfg.y_min      = 3700;
            cfg.y_max      = 200;
            cfg.pin_int    = -1;
            cfg.bus_shared = false;
            cfg.spi_host   = -1; // Software SPI
            cfg.pin_sclk   = 25;
            cfg.pin_mosi   = 32;
            cfg.pin_miso   = 39;
            cfg.pin_cs     = 33;
            _touch_instance.config(cfg);
            _panel_instance.setTouch(&_touch_instance);
        }
        setPanel(&_panel_instance);
    }
};

#elif defined(TARGET_WAVESHARE_S3)

#include <LovyanGFX.hpp>

#define SCREEN_WIDTH        240
#define SCREEN_HEIGHT       240
#define VIEWPORT_OFFSET_X   0
#define VIEWPORT_OFFSET_Y   0
#define ENABLE_DEBUG_STRIP  0

// Note: Verify GPIO pin assignments against Waveshare ESP32-S3-Touch-LCD-1.28 schematic
class LGFX : public lgfx::LGFX_Device {
    lgfx::Panel_GC9A01  _panel_instance;
    lgfx::Bus_SPI       _bus_instance;
    lgfx::Light_PWM     _light_instance;
    lgfx::Touch_CST816S _touch_instance;

public:
    LGFX(void) {
        {
            auto cfg = _bus_instance.config();
            cfg.spi_host   = SPI2_HOST;
            cfg.spi_mode   = 0;
            cfg.freq_write = 80000000;
            cfg.freq_read  = 20000000;
            cfg.spi_3wire  = true;
            cfg.use_lock   = true;
            cfg.dma_channel = SPI_DMA_CH_AUTO;
            cfg.pin_sclk   = 10;
            cfg.pin_mosi   = 11;
            cfg.pin_miso   = 12;
            cfg.pin_dc     = 8;
            _bus_instance.config(cfg);
            _panel_instance.setBus(&_bus_instance);
        }
        {
            auto cfg = _panel_instance.config();
            cfg.pin_cs           = 9;
            cfg.pin_rst          = 14;
            cfg.pin_busy         = -1;
            cfg.panel_width      = 240;
            cfg.panel_height     = 240;
            cfg.invert           = true;
            cfg.rgb_order        = false;
            cfg.bus_shared       = false;
            _panel_instance.config(cfg);
        }
        {
            auto cfg = _light_instance.config();
            cfg.pin_bl      = 2;
            cfg.invert      = false;
            cfg.freq        = 44100;
            cfg.pwm_channel = 7;
            _light_instance.config(cfg);
            _panel_instance.setLight(&_light_instance);
        }
        {
            auto cfg = _touch_instance.config();
            cfg.i2c_port   = 0;
            cfg.i2c_addr   = 0x15;
            cfg.pin_sda    = 6;
            cfg.pin_scl    = 7;
            cfg.pin_int    = 5;
            cfg.pin_rst    = 13;
            cfg.freq       = 400000;
            _touch_instance.config(cfg);
            _panel_instance.setTouch(&_touch_instance);
        }
        setPanel(&_panel_instance);
    }
};

#endif
