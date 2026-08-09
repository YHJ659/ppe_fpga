#ifndef MODEL6_HW_DRIVER_H
#define MODEL6_HW_DRIVER_H

#include <stdint.h>

struct model6_hw;

struct model6_hw *model6_create(void);
void model6_destroy(struct model6_hw *hw);
int model6_run(struct model6_hw *hw, const int8_t *input, int8_t *output,
               unsigned int timeout_ms);

#endif
