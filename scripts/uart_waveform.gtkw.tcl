# Preload the small set of signals used by tb_uart_waveform.sv.
set signals [list \
    tb_uart_waveform.phase\[1:0\] \
    tb_uart_waveform.serial_rx \
    tb_uart_waveform.rx_state\[2:0\] \
    tb_uart_waveform.rx_byte\[7:0\] \
    tb_uart_waveform.rx_byte_valid \
    tb_uart_waveform.word_data\[31:0\] \
    tb_uart_waveform.word_valid \
    tb_uart_waveform.received_byte_count\[5:0\] \
    tb_uart_waveform.received_word_count\[3:0\] \
    tb_uart_waveform.last_received_word\[31:0\]]

set added [gtkwave::addSignalsFromList $signals]
puts "Loaded $added UART lab signals"
gtkwave::/Edit/Set_Trace_Max_Hier 0
gtkwave::/Time/Zoom/Zoom_Full
