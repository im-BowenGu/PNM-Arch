cmake_minimum_required(VERSION 3.18)
project(pnm_sel4_root_task C ASM)

# Root task binary
add_executable(${PROJECT_NAME}
    main.c
)

target_link_libraries(${PROJECT_NAME} sel4c)
