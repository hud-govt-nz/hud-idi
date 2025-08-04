# Tools for working in the IDI. See https://github.com/hud-govt-nz/hud-idi.
library(tidyverse)
library(dbplyr, warn.conflicts = FALSE)
library(openxlsx)

# Connect to a database using a reference that we define in .Renviron.
#
# This means you can't directly tell it which DB to connect to. This is
# cumbersome BY DESIGN. Connecting to the wrong database (and trying to connect
# to data from separate IDI runs) will cause BOUNDLESS SADNESS, since snz_uid
# change between runs. Combining data from different runs will match completely
# unrelated entities to each other. VERY SAD. Only keep database names in
# .Renviron so there is a single point of truth.
db_connect <- function(db_ref) {
    db_name <- Sys.getenv(db_ref)
    con <- DBI::dbConnect(
        odbc::odbc(),
        driver = "ODBC Driver 18 for SQL Server", 
        server = "PRTPRDSQL36.stats.govt.nz, 1433",
        database = db_name,
        TrustServerCertificate = "YES",
        Trusted_Connection = "YES")

    return(con)
}


# Suppress values under 6
apply_suppression <- function(x, threshold = 6) {
    out <- ifelse(x < threshold, NA, x)

    return(out)
}


# Create hash strings for randomisation. Hash salt is just a unique string for
# adding entropy.
make_hash_base <- function(x, seg_cols, hash_salt) {
    out <-
        unite(x[seg_cols], "hb")[[1]] %>%
        paste(hash_salt, .)

    return(out)
}


# Apply random rounding (base 3) to a specific column, using a premade bash
# column for randomisation.
apply_frr3 <- function(x, hash_base) {
    col_name <- cur_column()
    message("Suppressing '", col_name, "'...")
    out <-
        tibble(
            x = x,
            # Use hash to make a random 1/3 roll and determine how far to jump
            hash_full = paste(hash_base, col_name, sep = ":"),
            roll = digest::digest2int(hash_full) %% 3,
            distance = if_else(roll == 0, -2, 1), # 1 means going to closest, -2 means going to the second closest
            # Jump using direction
            xr = x %% 3,
            direction = case_when(
                xr == 0 ~ 0, # Stay (already a product of 3)
                xr == 1 ~ -1, # Go down (nearest product of 3 is smaller)
                xr == 2 ~ 1), # Go up (nearest product of 3 is bigger)
            frr3 = x + (direction * distance))

    return(out$frr3)
}


# Write data into an Excel file with disclaimer and "S" for suppressed
write_release <- function(x, seg_cols, release_fn, template_fn, overwrite = FALSE) {
    message("Creating output release file '", release_fn, "'...")
    wb <- loadWorkbook(template_fn)
    x <- x %>% mutate(across(all_of(seg_cols), ~ replace_na(., "MISSING"))) # Put in placeholders for segmentation columns
    writeData(wb, "Data", x, keepNA = TRUE, na.string = "S") # All other NAs will be filled with "S" for suppressed
    saveWorkbook(wb, release_fn, overwrite)
}


# Read data from a release file and remove "S" for suppressed
read_release <- function(release_fn, seg_cols, sheet = "Data") {
    message("Reading output release file '", release_fn, "'...")
    out <-
        readWorkbook(release_fn, sheet) %>%
        as_tibble() %>%
        mutate(across(
            -all_of(seg_cols),
            ~ na_if(., "S") %>% as.double()))

    return(out)
}
