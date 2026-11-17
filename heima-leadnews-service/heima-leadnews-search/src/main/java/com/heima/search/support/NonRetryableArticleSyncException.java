package com.heima.search.support;

/** A payload that cannot be repaired by retrying the same record. Keep it in DLT. */
public class NonRetryableArticleSyncException extends RuntimeException {
    public NonRetryableArticleSyncException(String message) {
        super(message);
    }

    public NonRetryableArticleSyncException(String message, Throwable cause) {
        super(message, cause);
    }
}
