; COR.asm -- Menu-driven Certificate of Registration / assessment
; Windows x64, NASM + a 64-bit MinGW-w64 GCC toolchain.
;
; Build (in the directory containing this file):
;   nasm -f win64 COR.asm -o COR.obj
;   gcc -m64 COR.obj -o COR.exe
; Run in PowerShell: .\COR.exe
;
; All money is stored as INTEGER CENTAVOS, never binary floating point.
; Each entered fee: PHP 0.00 through PHP 1,000,000.00 inclusive.
; Grammar: digits, optionally '.' followed by one or two digits.
; Examples: 0, 1200, 1200.5, 1200.50. No signs/commas/exponents.
; Text: required, at most 99 bytes before trimming outer ASCII spaces.
; Control bytes (including tabs and embedded NUL) are rejected.
; Text fields are free-form: identifiers/phone numbers keep leading zeros.
; EOF (Ctrl+Z then Enter on Windows) exits without an input retry loop.
;
; Option 1 commits a record only after ALL fields and fees are valid.
; Option 3 overwrites COR.txt in the CURRENT WORKING DIRECTORY.
; Option 4 displays that file; it does not import a student record.
;
; Win64 ABI: every calling procedure has 32 bytes of shadow space,
; aligned calls, and locals separate from outgoing arguments. Only RBP
; among the nonvolatile registers is modified, and it is saved/restored.

bits 64
default rel

global main
extern printf, getchar, putchar, fopen, fclose, fprintf, fputs
extern fgetc, ferror, fflush, memcpy

%define TEXT_CAP        100
%define MAX_PESOS       1000000
%define MAX_CENTAVOS    (MAX_PESOS * 100)
%define TUITION_CENTS   (11 * 1000 * 100)

; Byte offsets in the active and staging records.
%define S_STATUS        0
%define S_ID            100
%define S_NAME          200
%define S_PHONE         300
%define S_ZIP           400
%define S_COLLEGE       500
%define S_PROGRAM       600
%define S_YEAR          700
%define S_TERM          800
%define S_SY            900
%define S_ADDRESS       1000
; Four padding bytes align the qword monetary fields.
%define S_MISC          1104
%define S_IDFEE         1112
%define S_LAB           1120
%define S_OTHER         1128
%define S_TOTAL         1136
%define S_DOWN          1144
%define S_MID           1152
%define S_FINAL         1160
%define RECORD_SIZE     1168

; Each frame size is a multiple of 16 and includes outgoing shadow space.
%macro PROC 2
%1:
    push rbp
    mov rbp, rsp
    sub rsp, %2
%endmacro

%macro ENDPROC 0
    leave
    ret
%endmacro

; Print a literal safely: user/file data is never a printf format string.
%macro SAY 1
    lea rcx, [fmt_text]
    lea rdx, [%1]
    call printf
%endmacro

; These two macros are used inside input_record, which owns .cancel.
%macro GET_TEXT 2
    lea rcx, [%1]
    lea rdx, [pending + %2]
    call read_text
    test eax, eax
    jz .cancel
%endmacro

%macro GET_FEE 2
    lea rcx, [%1]
    lea rdx, [pending + %2]
    call read_amount
    test eax, eax
    jz .cancel
%endmacro

; Shared report macros work for BOTH the screen and COR.txt.
%macro SHOW_TEXT 1
    lea rcx, [%1]
    call emit_text
%endmacro

%macro PRINT_FIELD 2
    lea rcx, [%1]
    lea rdx, [student + %2]
    call emit_field
%endmacro

%macro PRINT_MONEY 2
    lea rcx, [%1]
    mov rdx, [student + %2]
    call emit_money
%endmacro

%macro ADD_FEE 1
    add rax, [rcx + %1]
%endmacro

section .data

fmt_text   db "%s",0
field_fmt  db "%-20s : %s",10,0
; Peso quotients fit unsigned 32-bit values under the documented fee cap.
money_fmt  db "%-29s : PHP %u.%02u",10,0

menu:
    db 10,"============================================================",10
    db "                            COR",10
    db "============================================================",10
    db "1. Input student details and fees",10
    db "2. Display full COR and assessment",10
    db "3. Write full report to COR.txt (overwrite)",10
    db "4. Read and display COR.txt",10
    db "5. Exit",10
    db "Enter your choice: ",0

msg_choice db "Invalid choice. Enter exactly one digit from 1 to 5.",10,0
msg_text   db "Invalid text. Enter 1-99 bytes; no control characters or tabs.",10,0
msg_amount db "Invalid amount. Use 0 to 1000000 with at most 2 decimal places.",10,0
msg_saved_input db "Student details and fees recorded successfully.",10,0
msg_no_data db "No student record yet. Choose option 1 first.",10,0
msg_saved db "Full report saved to COR.txt.",10,0
msg_open_write db "Cannot open COR.txt for writing. Check the folder/permissions.",10,0
msg_write_error db "Save failed. COR.txt may be incomplete; check free space/permissions.",10,0
msg_open_read db "Cannot open COR.txt for reading. Save it first or check permissions.",10,0
msg_read_error db 10,"Error while reading or closing COR.txt.",10,0
msg_output_error db 10,"Error writing to the console/output stream.",10,0
msg_file_begin db 10,"================ CONTENTS OF COR.txt ================",10,0
msg_file_end db 10,"==================== END OF FILE ====================",10,0
msg_eof db 10,"End of input. Exiting.",10,0
msg_bye db "Goodbye.",10,0

filename db "COR.txt",0
mode_write db "wt",0
mode_read  db "rt",0

header:
    db 10,"============================================================",10
    db "              STUDENT ENROLLMENT ASSESSMENT",10
    db "============================================================",10,0

p_status  db "Enrollment Status: ",0
p_id      db "Student Number: ",0
p_name    db "Full Name: ",0
p_phone   db "Phone Number: ",0
p_zip     db "ZIP Code: ",0
p_college db "College: ",0
p_program db "Program: ",0
p_year    db "Year Level: ",0
p_term    db "Term: ",0
p_sy      db "School Year: ",0
p_address db "Address: ",0

input_title db 10,"Enter student information (required, maximum 99 bytes per field).",10,0
fee_title db 10,"Enter the four additional fees in PHP (0 to 1000000.00 each).",10,0
p_misc    db "Miscellaneous Fee: ",0
p_idfee   db "ID Validation Fee: ",0
p_lab     db "Laboratory Fees: ",0
p_other   db "Other Fees: ",0

student_title:
    db 10,"================ STUDENT INFORMATION ================",10,0

label_status  db "Enrollment Status",0
label_id      db "Student Number",0
label_name    db "Full Name",0
label_phone   db "Phone Number",0
label_zip     db "ZIP Code",0
label_college db "College",0
label_program db "Program",0
label_year    db "Year Level",0
label_term    db "Term",0
label_sy      db "School Year",0
label_address db "Address",0

course_header:
    db 10,"================ FIXED COURSE SCHEDULE ================",10
    db "CODE       TITLE                                  UNITS  DAY   TIME                    ROOM",10
    db "------------------------------------------------------------------------------------------------",10,0

; The original 11 course entries, units, days, times and rooms are fixed.
course1  db "CCS0021    INFORMATION MANAGEMENT (LEC)            2     T     16:00-18:40             ONLINE",10,0
course2  db "CCS0021L   INFORMATION MANAGEMENT (LAB)            1     F     16:00-18:50             ONLINE",10,0
course3  db "CSD001     DISCRETE STRUCTURES 1                   3     S/W   15:00-16:50/15:00-16:50 F710/F710",10,0
course4  db "CSD003     COMPUTER SYSTEMS & ARCHITECTURE         2     F     10:00-12:40             ONLINE",10,0
course5  db "CSD003L    COMPUTER SYSTEMS & ARCHITECTURE (LAB)   1     TH    10:00-12:50             E619",10,0
course6  db "CSD070     OBJECT ORIENTED PROGRAMMING             2     F     07:00-09:40             ONLINE",10,0
course7  db "CSD070L    OBJECT ORIENTED PROGRAMMING-LAB         1     TH    07:00-09:50             E609",10,0
course8  db "GED0021    SPECIALIZED ENGLISH LANGUAGE 2          3     S/W   11:00-12:50/11:00-12:50 F607/F607",10,0
course9  db "GED0055    MATHEMATICAL ANALYSIS                   3     S/W   09:00-10:50/09:00-10:50 F712/F712",10,0
course10 db "GED0081    COLLEGE PHYSICS 1 LECTURE               2     T     10:00-12:40             ONLINE",10,0
course11 db "GED0081L   COLLEGE PHYSICS LABORATORY              1     M     10:00-12:50             F1003",10,0

unit_total db "TOTAL UNITS: 21",10,"TOTAL COURSES: 11",10,0
assessment_title db 10,"================ TUITION ASSESSMENT ================",10,0
label_coursefee db "Course Fees (11 x PHP 1000)",0
label_misc      db "Miscellaneous Fee",0
label_idfee     db "ID Validation Fee",0
label_labfee    db "Laboratory Fees",0
label_otherfee  db "Other Fees",0
label_total     db "TOTAL ASSESSMENT",0
separator db "----------------------------------------------------",10,0
payment_title db 10,"================ PAYMENT SCHEDULE ==================",10,0
label_down  db "Down Payment (40%)",0
label_mid   db "Midterm (30%)",0
label_final db "Final Payment (30%)",0
rounding_note db "Payments rounded to centavos; final payment balances the total.",10,0

section .bss align=8
student       resb RECORD_SIZE
pending       resb RECORD_SIZE
line_buffer   resb TEXT_CAP
alignb 8
report_stream resq 1                ; NULL = console, otherwise FILE *
report_failed resd 1
record_ready  resd 1

section .text

PROC main, 32
.menu:
    SAY menu
    xor ecx, ecx
    call fflush
    lea rcx, [line_buffer]
    mov edx, TEXT_CAP
    call read_line
    test eax, eax
    jz .eof
    cmp eax, 1
    jne .bad_choice
    cmp byte [line_buffer + 1], 0
    jne .bad_choice
    movzx eax, byte [line_buffer]
    cmp eax, '1'
    je .input
    cmp eax, '2'
    je .display
    cmp eax, '3'
    je .save
    cmp eax, '4'
    je .read
    cmp eax, '5'
    je .exit
.bad_choice:
    SAY msg_choice
    jmp .menu
.input:
    call input_record
    test eax, eax
    jz .eof
    jmp .menu
.display:
    cmp dword [record_ready], 0
    je .no_data
    xor ecx, ecx
    call write_report
    test eax, eax
    jnz .menu
    SAY msg_output_error
    jmp .menu
.save:
    cmp dword [record_ready], 0
    je .no_data
    call save_report
    jmp .menu
.read:
    call read_report_file
    jmp .menu
.no_data:
    SAY msg_no_data
    jmp .menu
.eof:
    SAY msg_eof
    jmp .done
.exit:
    SAY msg_bye
.done:
    xor eax, eax
    ENDPROC

; Read all details into pending; copy only after successful completion.
; Returns EAX = 1 when committed, 0 if EOF interrupted input.
PROC input_record, 32
    SAY input_title
    GET_TEXT p_status,  S_STATUS
    GET_TEXT p_id,      S_ID
    GET_TEXT p_name,    S_NAME
    GET_TEXT p_phone,   S_PHONE
    GET_TEXT p_zip,     S_ZIP
    GET_TEXT p_college, S_COLLEGE
    GET_TEXT p_program, S_PROGRAM
    GET_TEXT p_year,    S_YEAR
    GET_TEXT p_term,    S_TERM
    GET_TEXT p_sy,      S_SY
    GET_TEXT p_address, S_ADDRESS
    SAY fee_title
    GET_FEE p_misc,  S_MISC
    GET_FEE p_idfee, S_IDFEE
    GET_FEE p_lab,   S_LAB
    GET_FEE p_other, S_OTHER
    lea rcx, [pending]
    call compute_assessment
    lea rcx, [student]
    lea rdx, [pending]
    mov r8d, RECORD_SIZE
    call memcpy
    mov dword [record_ready], 1
    SAY msg_saved_input
    mov eax, 1
    jmp .done
.cancel:
    xor eax, eax
.done:
    ENDPROC

; read_line(RCX = buffer, EDX = capacity including terminating NUL)
; Returns 1 = complete line, 0 = EOF with no input, -1 = invalid line.
; Drains overlong/invalid lines so nothing leaks into the next prompt.
; Accepts a nonempty last line without a newline at EOF. Trims ASCII spaces.
PROC read_line, 64
    mov [rbp - 8], rcx
    dec edx
    mov [rbp - 16], rdx            ; maximum stored byte count
    mov qword [rbp - 24], 0        ; stored length
    mov dword [rbp - 28], 0        ; invalid/overflow flag
.next:
    call getchar
    cmp eax, -1
    je .eof
    cmp eax, 10
    je .finish
    ; CRT text input already translates Windows CRLF to LF.
    cmp eax, 32
    jb .invalid
    cmp eax, 127
    je .invalid
    mov rdx, [rbp - 24]
    cmp rdx, [rbp - 16]
    jae .invalid
    mov rcx, [rbp - 8]
    mov [rcx + rdx], al
    inc qword [rbp - 24]
    jmp .next
.invalid:
    mov dword [rbp - 28], 1
    jmp .next
.eof:
    cmp qword [rbp - 24], 0
    jne .finish
    cmp dword [rbp - 28], 0
    jne .finish
    mov rcx, [rbp - 8]
    mov byte [rcx], 0
    xor eax, eax
    jmp .done
.finish:
    mov rcx, [rbp - 8]
    mov rdx, [rbp - 24]
    mov byte [rcx + rdx], 0
    cmp dword [rbp - 28], 0
    jne .bad
    mov r10, rcx                  ; first retained character
    lea r11, [rcx + rdx]           ; one beyond last retained character
.trim_left:
    cmp byte [r10], ' '
    jne .trim_right
    inc r10
    jmp .trim_left
.trim_right:
    cmp r11, r10
    jbe .copy_start
    cmp byte [r11 - 1], ' '
    jne .copy_start
    dec r11
    jmp .trim_right
.copy_start:
    mov r8, rcx
.copy:
    cmp r10, r11
    jae .terminate
    mov al, [r10]
    mov [r8], al
    inc r10
    inc r8
    jmp .copy
.terminate:
    mov byte [r8], 0
    mov eax, 1
    jmp .done
.bad:
    mov byte [rcx], 0
    mov eax, -1
.done:
    ENDPROC

; read_text(RCX = prompt, RDX = destination[TEXT_CAP]) -> EAX 1/0.
PROC read_text, 64
    mov [rbp - 8], rcx
    mov [rbp - 16], rdx
.retry:
    lea rcx, [fmt_text]
    mov rdx, [rbp - 8]
    call printf
    ; Flush prompts even when stdout is redirected.
    xor ecx, ecx
    call fflush
    mov rcx, [rbp - 16]
    mov edx, TEXT_CAP
    call read_line
    test eax, eax
    jz .done
    cmp eax, 1
    jne .bad
    mov rdx, [rbp - 16]
    cmp byte [rdx], 0
    jne .done                     ; EAX is already 1
.bad:
    SAY msg_text
    jmp .retry
.done:
    ENDPROC

; read_amount(RCX = prompt, RDX = destination qword) -> EAX 1/0.
PROC read_amount, 64
    mov [rbp - 8], rcx
    mov [rbp - 16], rdx
.retry:
    lea rcx, [fmt_text]
    mov rdx, [rbp - 8]
    call printf
    xor ecx, ecx
    call fflush
    lea rcx, [line_buffer]
    mov edx, TEXT_CAP
    call read_line
    test eax, eax
    jz .done
    cmp eax, 1
    jne .bad
    lea rcx, [line_buffer]
    call parse_amount
    test eax, eax
    jz .bad
    mov rcx, [rbp - 16]
    mov [rcx], rdx
    jmp .done
.bad:
    SAY msg_amount
    jmp .retry
.done:
    ENDPROC

; Strict decimal parser, leaf procedure. No C conversion can accept a
; numeric prefix while silently ignoring junk. Bounds checked per digit.
; RCX = trimmed string; returns EAX = 1 and RDX = centavos, or EAX = 0.
parse_amount:
    xor r8d, r8d                  ; whole pesos
    xor r10d, r10d                ; fractional centavos
    movzx eax, byte [rcx]
    sub eax, '0'
    cmp eax, 9
    ja .bad                       ; at least one whole-number digit
.whole:
    imul r8, r8, 10
    add r8, rax
    cmp r8, MAX_PESOS
    ja .bad                       ; stops overflow before next multiply
    inc rcx
    movzx eax, byte [rcx]
    cmp eax, '0'
    jb .after_whole
    cmp eax, '9'
    ja .after_whole
    sub eax, '0'
    jmp .whole
.after_whole:
    test eax, eax
    jz .convert
    cmp eax, '.'
    jne .bad
    inc rcx
    movzx eax, byte [rcx]
    sub eax, '0'
    cmp eax, 9
    ja .bad                       ; reject a bare trailing decimal point
    imul r10d, eax, 10
    inc rcx
    cmp byte [rcx], 0
    je .convert                   ; one fractional digit, e.g. 1.2
    movzx eax, byte [rcx]
    sub eax, '0'
    cmp eax, 9
    ja .bad
    add r10d, eax
    inc rcx
    cmp byte [rcx], 0
    jne .bad                      ; no third digit or trailing junk
.convert:
    imul rdx, r8, 100
    add rdx, r10
    cmp rdx, MAX_CENTAVOS
    ja .bad
    mov eax, 1
    ret
.bad:
    xor edx, edx
    xor eax, eax
    ret

; RCX = record. Round 40% and 30% to the nearest centavo, half up;
; final = total - down - mid, so displayed payments ALWAYS sum to total.
compute_assessment:
    mov eax, TUITION_CENTS
    ADD_FEE S_MISC
    ADD_FEE S_IDFEE
    ADD_FEE S_LAB
    ADD_FEE S_OTHER
    mov [rcx + S_TOTAL], rax
    mov r8d, 100
    imul rax, rax, 40
    add rax, 50
    xor edx, edx
    div r8
    mov [rcx + S_DOWN], rax
    mov rax, [rcx + S_TOTAL]
    imul rax, rax, 30
    add rax, 50
    xor edx, edx
    div r8
    mov [rcx + S_MID], rax
    mov rax, [rcx + S_TOTAL]
    sub rax, [rcx + S_DOWN]
    sub rax, [rcx + S_MID]
    mov [rcx + S_FINAL], rax
    ret

; One report definition guarantees screen and saved file have all fields.
; RCX = NULL for console, FILE * for file. Returns EAX 1 success / 0 error.
PROC write_report, 32
    mov [report_stream], rcx
    mov dword [report_failed], 0
    SHOW_TEXT header
    SHOW_TEXT student_title
    PRINT_FIELD label_status,  S_STATUS
    PRINT_FIELD label_id,      S_ID
    PRINT_FIELD label_name,    S_NAME
    PRINT_FIELD label_phone,   S_PHONE
    PRINT_FIELD label_zip,     S_ZIP
    PRINT_FIELD label_college, S_COLLEGE
    PRINT_FIELD label_program, S_PROGRAM
    PRINT_FIELD label_year,    S_YEAR
    PRINT_FIELD label_term,    S_TERM
    PRINT_FIELD label_sy,      S_SY
    PRINT_FIELD label_address, S_ADDRESS
    SHOW_TEXT course_header
    SHOW_TEXT course1
    SHOW_TEXT course2
    SHOW_TEXT course3
    SHOW_TEXT course4
    SHOW_TEXT course5
    SHOW_TEXT course6
    SHOW_TEXT course7
    SHOW_TEXT course8
    SHOW_TEXT course9
    SHOW_TEXT course10
    SHOW_TEXT course11
    SHOW_TEXT unit_total
    SHOW_TEXT assessment_title
    lea rcx, [label_coursefee]
    mov edx, TUITION_CENTS
    call emit_money
    PRINT_MONEY label_misc,     S_MISC
    PRINT_MONEY label_idfee,    S_IDFEE
    PRINT_MONEY label_labfee,   S_LAB
    PRINT_MONEY label_otherfee, S_OTHER
    SHOW_TEXT separator
    PRINT_MONEY label_total, S_TOTAL
    SHOW_TEXT payment_title
    PRINT_MONEY label_down,  S_DOWN
    PRINT_MONEY label_mid,   S_MID
    PRINT_MONEY label_final, S_FINAL
    SHOW_TEXT rounding_note
    mov rcx, [report_stream]       ; specific file, or NULL for console
    call fflush                   ; also detects buffered output errors
    test eax, eax
    jz .status
    mov dword [report_failed], 1
.status:
    mov eax, [report_failed]
    xor eax, 1
    ENDPROC

; emit_text(RCX = text). fputs and printf are checked for negative return.
PROC emit_text, 32
    mov rdx, [report_stream]
    test rdx, rdx
    jnz .file
    mov rdx, rcx
    lea rcx, [fmt_text]
    call printf
    jmp .check
.file:
    call fputs
.check:
    test eax, eax
    jns .done
    mov dword [report_failed], 1
.done:
    ENDPROC

; emit_field(RCX = label, RDX = value).
PROC emit_field, 32
    mov r9, rdx
    mov r8, rcx
    mov rcx, [report_stream]
    test rcx, rcx
    jnz .file
    lea rcx, [field_fmt]
    mov rdx, r8
    mov r8, r9
    call printf
    jmp .check
.file:
    lea rdx, [field_fmt]
    call fprintf
.check:
    test eax, eax
    jns .done
    mov dword [report_failed], 1
.done:
    ENDPROC

; emit_money(RCX = label, RDX = integer centavos).
; fprintf has FIVE arguments; its last argument is above shadow space.
PROC emit_money, 48
    mov r10, rcx
    mov rax, rdx
    xor edx, edx
    mov r11d, 100
    div r11                       ; RAX = pesos, RDX = centavos 0..99
    mov rcx, [report_stream]
    test rcx, rcx
    jnz .file
    mov r9d, edx
    mov r8d, eax
    mov rdx, r10
    lea rcx, [money_fmt]
    call printf
    jmp .check
.file:
    mov [rsp + 32], rdx            ; fifth argument, outside shadow space
    mov r9d, eax
    mov r8, r10
    lea rdx, [money_fmt]
    call fprintf
.check:
    test eax, eax
    jns .done
    mov dword [report_failed], 1
.done:
    ENDPROC

; Caller ensures a complete student record exists.
PROC save_report, 64
    lea rcx, [filename]
    lea rdx, [mode_write]
    call fopen
    test rax, rax
    jz .open_error
    mov [rbp - 8], rax
    mov rcx, rax
    call write_report
    xor eax, 1                    ; remember error, not success
    mov [rbp - 12], eax
    mov rcx, [rbp - 8]
    call ferror
    or [rbp - 12], eax
    mov rcx, [rbp - 8]
    call fclose                   ; closing/flushing may also fail
    or eax, [rbp - 12]
    mov qword [report_stream], 0   ; never leave a closed FILE * selected
    test eax, eax
    jnz .write_error
    SAY msg_saved
    jmp .done
.open_error:
    SAY msg_open_write
    jmp .done
.write_error:
    SAY msg_write_error
.done:
    ENDPROC

; Streams the entire text file, without a fixed-size file buffer and
; without interpreting percent signs in the file as format specifiers.
; This menu operation works even before option 1 has been used.
PROC read_report_file, 64
    lea rcx, [filename]
    lea rdx, [mode_read]
    call fopen
    test rax, rax
    jz .open_error
    mov [rbp - 8], rax
    mov dword [rbp - 12], 0        ; read/close error
    mov dword [rbp - 16], 0        ; output error
    SAY msg_file_begin
.next:
    mov rcx, [rbp - 8]
    call fgetc
    cmp eax, -1
    je .finish
    mov ecx, eax
    call putchar
    cmp eax, -1
    jne .next
    mov dword [rbp - 16], 1
.finish:
    mov rcx, [rbp - 8]
    call ferror
    or [rbp - 12], eax
    mov rcx, [rbp - 8]
    call fclose
    or [rbp - 12], eax
    xor ecx, ecx
    call fflush
    or [rbp - 16], eax
    cmp dword [rbp - 16], 0
    jne .output_error
    cmp dword [rbp - 12], 0
    jne .read_error
    SAY msg_file_end
    jmp .done
.open_error:
    SAY msg_open_read
    jmp .done
.read_error:
    SAY msg_read_error
    jmp .done
.output_error:
    SAY msg_output_error
.done:
    ENDPROC
