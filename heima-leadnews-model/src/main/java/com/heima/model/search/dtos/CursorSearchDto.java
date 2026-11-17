package com.heima.model.search.dtos;
import lombok.Data;
/** New cursor API; the old UserSearchDto and endpoint remain compatible. */
@Data
public class CursorSearchDto {
    private String searchWords;
    private Integer pageSize;
    private String cursor;
    private Long upperBoundMillis;
}
