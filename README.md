# hud-idi
Handy library of tools to being into the IDI. See [hud-govt-nz/social-housing-gap](https://github.com/hud-govt-nz/social-housing-gap) for an example of how it's used.

There might already be a copy of this project inside your IDI project. If not, ask `Access2Microdata-SharedMailbox@stats.govt.nz` to load it into your project (see "Managing Github repos" below).

Of the output rules, only "suppress counts under 6" and "round randomly to a base of 3" have been implemented. Feel free to add to this with column-wise functions.


## Managing Github repos
Version control inside the IDI is tricky, since commits can't be pushed/pulled from inside the IDI. We can get around this by using `git bundle`, which bundles commits into a single file, which can then be put in (by asking `Access2Microdata-SharedMailbox@stats.govt.nz`) or pulled out (via the output process).

For the initial bundle, you'll need to bundle everything:
```
git bundle create project_name.bundle -all
```

Request for the bundle file to be put into the IDI, and then from inside the IDI, run:
```
git clone project_name.bundle
```

To update projects once they've been created, you'll want to bundle commits with:
```
git log --oneline # Check which commits you want to bundle
git bundle create project_name_20250801.bundle 5182737..HEAD # Replace 5182737 with the actual commit ID
```

And the from inside the IDI run:
```
git pull project_name_20250801.bundle
```


## Generating outputs
We can use `hud-idi` to do the chores required to prepare outputs for checking:
* Apply suppression and rounding rules (`apply_suppression()` and `apply_frr3()`)
* Mark suppressed cells with "S" (`write_release()` takes care of this)
* Save unsuppressed/unrounded values in a `_raw` file
* Save suppressed/rounded values, with a disclaimer in a `FOR_RELEASE` file

```{r}
library(tidyverse)
source("code/hud_idi.R")

hash_salt <- "fe5dcebb62caa35d6cab3258c62088bb" # Random key so RR3 can't be reverse engineered (unless you have this string)
seg_cols <- c("area_type", "area_code", "household_type") # Definition columns for the row (i.e. Not values)
val_cols < c("hhld_count", "shd_count", "something_else_count") # Actual values

message("Applying suppression rules and RR3...")
output_raw <-
    read_csv("outputs/output_raw.csv", show_col_types = FALSE)

output_frr3 <-
    output_raw %>%
    mutate(
        hash_base = make_hash_base(., seg_cols, hash_salt), # Create base hash string
        # All counts columns are IDI unweighted counts, so...
        across(all_of(val_cols), ~ apply_suppression(., threshold = 6)), # ...suppress counts under 6
        across(all_of(val_cols), ~ apply_frr3(., hash_base))) %>% # ...and apply RR3
    select(-hash_base)

write_csv(output_raw, "outputs/summary_20250630_raw.csv")
write_release(
    output_frr3,
    seg_cols,
    "docs/output_template.xlsx",
    "outputs/summary_20250630_FOR_RELEASE.xlsx")
```

### Hot output tips
Having a single consistent table will make the output process simpler and faster.

* Instead of producing an output file for each area type (TA/region etc), add `area_type`/`area_code` columns (e.g. [`ta`, `076`], [`reg`, `01`], [`nz`, `nz`]) and save them all in a single file
* Keep the output types simple - instead of proportions, just output the counts and calculate the proportions outside the IDI
* You only need secondary suppression when the sum and all its components (e.g. "pop total", "pop >=65", "pop 21-64", "pop <21") are in the output; simply drop one (e.g. Drop "pop 21-64", leaving "pop total", "pop >=65", "pop <21") and the rule no longer applies!


## Using `dbplyr` in the IDI
It is **strongly** recommended that you access the IDI through `db_connect()` provided by `hud-idi`. This requires that you declare the tables that you're using in `.Renviron`. The purpose of this is create a single point of truth for the tables that are being accessed in a project. This is important because if you mix up the table names (i.e. Try to connect data from `IDI_Clean_202503` and `IDI_Clean_202506`) you will be **allowed** to match using IDs (specifically, `snz_uid`) which change between runs. This will result in completely unrelated entities being matched to each other. Everything will be very borked and you won't understand why and you will be very sad.

Declare tables in `.Renviron` like so:
```
idi_clean="IDI_Clean_202503"
idi_community="IDI_Community"
idi_metadata="IDI_Metadata_202503"
```

...and in your code, `db_connect()` will be able to use the named tables:
```{r}
library(tidyverse)
source("code/hud_idi.R")

individual_demographics <-
    db_connect("idi_clean") %>%
    tbl(I("cen_clean.census_individual_2023")) %>%
    select(
        snz_uid, snz_cen_hhld_uid, snz_cen_fam_uid, snz_cen_ext_fam_uid,
        cen_ind_age_code, cen_ind_living_arrangmnts_code) %>%
    collect()
```

### Hot `dbplyr` tips
`dbplyr` is a wrapper that translate R code into SQL behind the scenes. This means all the work is done on the database, rather than the virtual machine you're working on. This is a big advantage if the task is computationally expensive, but there are drawbacks.

* `dbplyr` can't translate everything (e.g. `grepl()`). This means if you want to use those functions, you'll need to load the table into your virtual machine using `collect()` first.
* The Census is extremely column-heavy. If you run `collect()` on Census you'll get a massive table which will take a long time to load and is very difficult to work with. So, use `select()` to pick the columns you need before `collect()`.
* You cannot join between different data sources (e.g. `IDI_Clean_202503` and `IDI_Community`) in `dbplyr`. `collect()` them and join them on your virtual machine.

```{r}
library(tidyverse)
source("code/hud_idi.R")

individual_demographics <-
    db_connect("idi_clean") %>%
    tbl(I("cen_clean.census_individual_2023")) %>%
    select(
        snz_uid, snz_cen_hhld_uid, snz_cen_fam_uid, snz_cen_ext_fam_uid,
        cen_ind_age_code, cen_ind_living_arrangmnts_code,
        cen_ind_family_role_code, cen_ind_dsblty_ind_code,
        cen_ind_ethgr_maori_ind_code, cen_ind_ethgr_pacific_ind_code,
        cen_ind_shd_code) %>%
    collect() %>% # grepl() below won't work inside tbl()
    mutate(
        ind_age = as.integer(cen_ind_age_code),
        is_adult = ind_age >= 18,
        is_child = ind_age < 18,
        is_senior = ind_age >= 65,
        is_flatmate = grepl("061[12]", cen_ind_living_arrangmnts_code),
        is_yng_flatmate = is_flatmate & ind_age > 15 & ind_age < 26,
        is_boarder = grepl("062[678]", cen_ind_living_arrangmnts_code))
```
