
#' Downloading EUPP Datasets
#'
#' Main function downloading data.
#'
#' @param x an object of class \code{\link{eupp_config}}.
#' @param output_file character length 1, name of the output file.
#' @param output_format character length 1, defaults to \code{"grib"}.
#'        Alternatively (somewhat experimental) \code{"nc"}.
#' @param overwrite logical length 1, defaults to \code{FALSE}. If set to \code{TRUE}
#'        the \code{output_file} will be overwritten if needed. If \code{FALSE} and
#'        \code{output_file} exists an error will be raised.
#' @param netcdf_kind numeric length 1, defaults to \code{3}. Controls the
#'        \code{-k} (kind) flag when calling \code{grib_to_netcdf}. Only used
#'        when \code{output_format = "nc"}.
#' @param verbose logical length 1, verbosity, defaults to \code{FALSE}.
#'
#' @details The function allows to store data sets in either GRIB version 1 or
#' NetCDF (classic 64bit; v3). The original data set is provided as GRIB, the 
#' conversion to NetCDF is done locally usning ECMWFs ecCodes tools which must
#' be installed when using NetCDF.
#'
#' The default mode is to download the data in the GRIB version 1 format. The data
#' set will be stored as \code{output_file} alongside with an \code{.rds} file containing
#' the information about the fields (the GRIB index information used for downloading).
#' Whilst this information can be read from the GRIB file (e.g,. via ecCodes \code{grib_ls}),
#' however, this allows us to interpolate GRIB files without the need of ecCodes to
#' be installed (using the \code{.rds} and \code{\link[stars]{read_stars}} via gdal).
#'
#' If \code{output_format = "nc"} a request must contain only one date in \code{x}.
#' The reason is that NetCDF does not allow for overlapping 'time'+'step' specifications.
#' Somewhat inconvenient but there is no general solution for that in ecCodes (or, to 
#' be precise, the NetCDF standard definition). PLEASE NOTE that this is somewhat
#' experimental and may not always be the best choice as \code{grib_to_netcdf} will
#' drop unrequired dimensions, thus losing information (e.g., if only one level or only
#' one perturbationNumber is present).
#'
#' @return No explicit return, invisibly returns the inventory of the file as a
#' \code{data.frame}.
#'
#' @importFrom httr GET add_headers
#' @importFrom tools file_ext
#' @importFrom utils txtProgressBar setTxtProgressBar
#'
#' @author Reto Stauffer
#' @rdname gridded
#' @export
eupp_download_gridded <- function(x,
                             output_file,
                             output_format = "grib",
                             overwrite = FALSE,
                             netcdf_kind = 3L,
                             verbose = FALSE) {

    # Checking main input object
    stopifnot(inherits(x, c("eupp_config", "eupp_inventory")))
    stopifnot(isTRUE(verbose)   || isFALSE(verbose))
    stopifnot(isTRUE(overwrite) || isFALSE(overwrite))

    # Sanity check for putput file
    stopifnot(is.character(output_file), length(output_file) == 1L)
    if (dir.exists(output_file)) stop("'output_file' is an existing directory.")
    # TODO: We can also just ... kill it?
    if (!overwrite && file.exists(output_file)) stop("'output_file' exists.")
    # Checking if output path exists
    if (!dir.exists(dirname(output_file)))
        stop("Cannot write 'output_file' to \"{:s}\", directory does not exist.", dirname(output_file))

    # If the user requests netCDF: check grib_to_netcdf is available.
    output_format <- match.arg(output_format, c("grib", "nc"))
    if (output_format == "nc") {
        if (length(x$date) > 1) {
            stop("Downloading multiple dates in NetCDF format/stars not allowed (see Details).")
        }
        gset     <- Sys.which("grib_set")
        g2nc_bin <- Sys.which("grib_to_netcdf")
        if (nchar(gset) == 0 || nchar(g2nc_bin) == 0) {
            # Stop
            stop("To be able to use 'output_format = \"nc\" the eccodes binaries must be installed. Requires both 'grib_set' and 'grib_to_netcdf' for the conversion.n")
        }

        # Checking argument netcdf_kind. This is controlling the -k (kind)
        # option when calling grib_to_netcdf to convert the GRIB file to NetCDF.
        stopifnot(is.numeric(netcdf_kind), length(netcdf_kind) == 1)
        netcdf_kind <- as.integer(netcdf_kind)
        stopifnot(netcdf_kind >= 1L, netcdf_kind <= 4L)
    }


    # We will make use of stars for spatial subsets which
    # is only possible if we store the data as NetCDF.
    if (output_format != "nc" & !is.null(x$area))
        stop("Areal subsets ('eupp_config area') only allowed in combination with NetCDF file format.")

    # Reforecasts only initialized on Mondays (1) and Thursdays (4)
    if (grepl("^reforecast$", x$product) && !all(format(x$date, "%w") %in% c(1, 4)))
        stop("Reforecasts only available on Mondays and Thursdays, check 'date'.")

    # ----------------------------------------------
    # Main content of the function
    # ----------------------------------------------
    inv       <- eupp_get_inventory(x, verbose = verbose) # Loading inventory information
    BASEURL   <- eupp_get_url_config()$BASEURL
    tmp_file  <- tempfile(fileext = ".grb")  # Temporary location for download

    # Open binary file connection; temporary file.
    # Download everything and then create final ouptut file.
    con      <- file(tmp_file, "wb")
    if (verbose) {
        cat("  Downloading grib messages (", nrow(inv), ") ...\n", sep = "")
        pb <- txtProgressBar(0, nrow(inv), style = 3)
    }

    # Looping over all rows of the inventory and download the data
    for (i in seq_len(nrow(inv))) {
        if (verbose) setTxtProgressBar(pb, i)
        rng <- sprintf("bytes=%.0f-%.0f", inv$offset[i], inv$offset[i] + inv$length[i])
        req <- GET(paste(BASEURL, inv$path[i], sep = "/"), add_headers(Range = rng))
        # Checking for status 200/206
        if (!status_code(req) %/% 100L == 2L)
            stop(sprintf("Problems accessing \"%s/%s\" (%s); return code %d.",
                         BASEURL, inv$path[i], rng, status_code(req)))
        writeBin(req$content, con = con)
    }
    if (verbose) close(pb)
    close(con) # Properly closing the binary file connection

    # Move file to final destination
    if (output_format == "grib") {
        file.rename(tmp_file, output_file)
        saveRDS(inv, sprintf("%s.rds", output_file))
    } else {
        if (verbose) cat("  Converting grib file to netcdf\n")
        tmp_file2 <- tempfile(fileext = ".grb")  # Second temporary file; required for grib_set
        # Setting 'number' (perturbation number) for control forecasts to 0 and
        # change type from 'cf' (control forecast) to 'pf' (perturbed forecast)
        # not to lose the control run during conversion from grib1 to netcdf.
        if (!is.null(x$type) && x$type == "ens") {
            system(sprintf("%s -s number=0 -w type=cf %s %s", gset, tmp_file, tmp_file2), intern = !verbose)
            system(sprintf("%s -s type=pf -w type=cf %s %s",  gset, tmp_file2, tmp_file), intern = !verbose)
            file.remove(tmp_file2) # Delete one of the intermediate temporary files
        }
        CMD <- sprintf("%s %s -k %d -o %s", g2nc_bin, tmp_file, netcdf_kind, output_file)
        system(CMD, intern = !verbose)
        file.remove(tmp_file) # Delete temporary file
    }

    invisible(inv)
}


#' Getting Grib Data as stars
#'
#' Requires ncdf4 and the NetCDF Library to be installed.
#'
#' @param x object of class \code{\link{eupp_config}}.
#' @param verbose logical, sets verbosity level. Defaults to \code{FALSE}.
#'
#' @return Object of class \code{c("eupp_stars", "stars")}; see Details.
#'
#' @details This function interfaces \code{\link{eupp_download_gridded}}
#' to download the data and converts the original data set (GRIB version 1)
#' to NetCDF. Thus NetCDF support and ecCodes tools are required and it only
#' allows data for one specific date in \code{x}. See 'Details' section
#' in \code{link{eupp_download_gridded}}.
#'
#' The function \code{\link[stars]{read_stars}} is used to read the NetCDF
#' file; note that the NetCDF file will be deleted after reading. The additional
#' class \code{eupp_stars} is used to provide additional support for processing
#' the data.
#'
#' If \code{x} (\code{\link{eupp_config}}) contains a \code{bbox} definition
#' on \code{area} the data is subsetted directly.
#'
#' @seealso \code{\link{eupp_download_gridded}} and \code{\link{eupp_stars}}
#'
#' @importFrom stars read_stars
#' @importFrom ncdf4 nc_open nc_close
#' @author Reto Stauffer
#' @rdname gridded
#' @export
eupp_get_gridded <- function(x, verbose = FALSE) {
    stopifnot(inherits(x, "eupp_config"))
    stopifnot(isTRUE(verbose) || isFALSE(verbose))
    stopifnot(requireNamespace("stars", quietly = TRUE))

    tmp_file <- tempfile(fileext = ".nc")
    on.exit(print(tmp_file))
    on.exit(print(tmp_file))
    on.exit(print(tmp_file))
    on.exit(print(tmp_file))
    on.exit(file.remove(tmp_file, showWarnings = FALSE))
    inv <- eupp_download_gridded(x, tmp_file, "nc", verbose = verbose)

    # Reading the NetCDF file as stars
    data <- read_stars(tmp_file, quiet = !verbose)

    # When having only one variable/parameter 'stars' names the
    # variable like the file. We are checking that. In case this is the case,
    # the variable name will be read from the NetCDF file.
    if (length(names(data)) == 1L && names(data) == basename(tmp_file)) {
        nc <- ncdf4::nc_open(tmp_file)
        names(data) <- names(nc$var)
        ncdf4::nc_close(nc)
    }

    # Return; perform subsetting if required
    if (!is.null(x$area)) data[x$area]
    class(data) <- c("eupp_stars", class(data))
    return(data)
}


#' @param times positive numeric, defaults to \code{3L}. Number of
#'        retries in case the GET request fails.
#'
#' @rdname gridded
#' @importFrom dplyr bind_rows
#' @importFrom rjson fromJSON
#' @importFrom digest digest
#' @importFrom httr GET RETRY status_code content
#' @export
eupp_get_inventory <- function(x, times = 3L, verbose = FALSE) {

    stopifnot(inherits(x, "eupp_config"))
    stopifnot(is.numeric(times), length(times) == 1L)

    # Getting the URL where the grib file index is stored
    index_url <- do.call(eupp_get_source_urls, list(x = x, fileext = "index"))

    # Helper function to download and parse requests
    fn_GET <- function(x) {
        request <- RETRY("GET", x, times = times)
        if (!status_code(request) == 200L)
            stop(sprintf("Problems accessing \"%s\"; return code %d.", x, status_code(request)))
        tmp <- readLines(con = textConnection(content(request, "text", encoding = "UTF-8")))
        return(tmp[sapply(tmp, nchar) > 0])
    }

    # In case caching is used:
    # - hashing URL for unique file names
    # - If file does exist on disc: read file
    # - Else download data; save to cache file for next time
    inv <- list()
    for (i in seq_along(index_url)) {
        if (verbose) cat("  Accessing", basename(index_url[i]), "\n")
        if (is.character(x$cache)) {
            # Create file <cache_dir>/<hashed_url>-<version>.index
            cached_file <- file.path(x$cache, sprintf("%s-%s.index.rds", digest(index_url[i]), x$version))
            if (file.exists(cached_file)) {
                if (verbose) cat("  - Index cached: loading", cached_file, "\n")
                tmp <- readRDS(cached_file)
            } else {
                if (verbose) cat("  - Index not cached: download and store as", cached_file, "\n")
                tmp <- fn_GET(index_url[i])
                tmp <- lapply(tmp, fromJSON)
                saveRDS(tmp, cached_file)
            }
            inv <- c(inv, tmp)
        # In case cache is NULL (default): request and extract
        } else {
            inv <- c(inv, lapply(fn_GET(index_url[i]), fromJSON))
        }
    }

    # - Convert to data.frame and fix leading underscores (not good)
    inv <- as.data.frame(bind_rows(inv))
    names(inv) <- gsub("^_(?=[a-zA-Z])", "", names(inv), perl = TRUE)
    inv <- transform(inv, init  = as.POSIXct(paste(date, time), tz = "UTC", format = "%Y%m%d %H%M"))

    # - Control run (type = "cf") has no 'number'; set to member number 0
    inv$number[inv$type == "cf"] <- 0

    # Extracting 'step' as integer. We either only get an integer (as text)
    # such as "0" or "12", or a step range like "0-12" or "24-48". In both
    # cases we extract the last numeric part and store it on 'step' again.
    # To keep the old 'step' (from the index file) we will rename it to 'step_char'.
    names(inv)[names(inv) == "step"] <- "step_char"
    inv$step <- as.integer(regmatches(inv$step_char, regexpr("[0-9]+$", inv$step_char))) # <- integer
    inv <- transform(inv, valid = init + step * 3600)
    inv <- transform(inv, step  = as.integer(inv$step))
    inv <- within(inv, {date <- time <- NULL})

    # Coerce 'number' (member number) to integer if available
    if (!is.null(inv$number)) inv$number <- as.integer(inv$number)
    # Subset or members if required
    if (!is.null(x$members)) inv <- subset(inv, number %in% x$members)

    # Subsetting to what the user has requested
    if (x$product == "analysis") {
        inv <- subset(inv, as.Date(valid) %in% as.Date(x$date))
        if (is.integer(x$steps)) inv <- subset(inv, as.POSIXlt(valid)$hour %in% x$steps)
    } else {
        inv <- subset(inv, init %in% x$date)
        if (is.integer(x$steps)) inv <- subset(inv, step  %in% x$steps)
    }
    if (is.character(x$parameter))     inv <- subset(inv, param %in% x$parameter)

    class(inv) <- c("eupp_inventory", class(inv))
    if (nrow(inv) == 0) warning("No field match found; check your 'eupp_config()' settings.")
    return(inv)
}


#' Interpolate GRIB File
#'
#' Allows to extract and interpolate specific locations
#' from grib files (see \code{\link{eupp_get_gridded}}).
#' Requires ecCodes to be installed.
#'
#' @param file character, name of the grib file from which
#'        the data should be extracted.
#' @param at object of class \code{sf} or \code{sfc} containing
#'        point locations to be extracted/interpolated.
#' @param atname \code{NULL} (default) or character length \code{1}.
#'        Is set (and the variable exists in \code{at}) it will be
#'        appended to the returned object.
#' @param bilinear logical, defaults to \code{TRUE}. If set to
#'        \code{FALSE} nearest neighbour interpolation is used.
#' @param wide logical, defaults to \code{TRUE}. If \code{TRUE} the
#'        result is in a wide format, else long format.
#' @param verbose logical, defaults to \code{FALSE}.
#' @param ignore_init logical, defaults to \code{FALSE}; see 'Details' for more
#'         information. Only has an effect when \code{wide = TRUE}.
#' @param ... currently unused.
#'
#' @details When downloading the GRIB version 1 data sets using
#' \code{\link{eupp_get_gridded()}} a \code{.rds} file with the grib
#' inventory will be stored alongside with the GRIB file itself. If
#' prsent, this \code{.rds} file will be used to retrieve the meta information
#' (what the different fields of the GRIB file contain).
#'
#' If not present, ecCodes must be installed and the index will be created
#' by calling \code{grib_ls -j}.
#'
#' It then reads the grib file using \code{\link[stars]{read_stars}}
#' to read the data (in bands) and performs the interpolation using
#' \code{\link[stars]{st_extract}}.
#'
#' Please note that \code{at} needs a valid coordinate reference
#' system (CRS) and must only contain \code{POINT} geometries for now.
#'
#' \code{wide}: Brings the interpolated data to a wide format. Reduces the
#' amount of meta information. See also \code{ignore_init} below when working
#' with analysis data.
#'
#' \code{ignore_init}: This option can be handy when processing analysis data.
#' Analysis data (ERA5 reanalysis) consists of variables coming from the analysis
#' directly (e.g., air temperature) and short-term predictions for certain parameters
#' such as precipitation. Thus, initialization date/time and time valid differs
#' between them resulting in a 'sparse' matrix if \code{wide = TRUE}. The argument
#' \code{ignore_init} allows to ignore initialization date/time and forecast step
#' to get a less (or non-)sparse data.frame. WARNING: When used with forecast data
#' the data may no longer be unique leading to overlapping data (warnings/errors).
#'
#' @importFrom sf st_geometry_type  st_transform st_crs
#' @importFrom stars read_stars st_extract
#' @importFrom rjson fromJSON
#' @importFrom dplyr bind_rows
#' @importFrom tidyr pivot_wider
#'
#' @author Reto Stauffer
#' @export
eupp_interpolate_grib <- function(file, at, atname = NULL, bilinear = TRUE, wide = TRUE, verbose = FALSE, ignore_init = FALSE, ...) {

    stopifnot(is.character(file), length(file) == 1L, file.exists(file))
    stopifnot(inherits(at, c("sf", "sfc")))
    stopifnot(is.null(atname) || is.character(atname))
    if (is.character(atname)) stopifnot(length(atname) == 1L)
    stopifnot(isTRUE(bilinear) || isFALSE(bilinear))
    stopifnot(isTRUE(wide) || isFALSE(wide))
    stopifnot(isTRUE(verbose) || isFALSE(verbose))
    stopifnot(isTRUE(ignore_init) || isFALSE(ignore_init))

    # Checking at
    if (verbose) cat("Interpolating GRIB file\n   - Checking location geometry\n")
    stopifnot(all(st_geometry_type(at) == "POINT"))
    if (is.na(st_crs(at))) stop("Object 'at' does not contain a valid coordinate reference system (CRS).")

    # Find grib_ls
    rdsfile <- sprintf("%s.rds", file)
    if (file.exists(rdsfile)) {
        if (verbose) cat("   -", rdsfile, "exists; using this for field meta info/index\n")
        inv <- readRDS(rdsfile)
    } else {
        if (verbose) cat("   -", rdsfile, "does not exist, calling 'grib_ls'\n")
        gls <- Sys.which("grib_ls")
        if (nchar(gls) == 0) stop("Cannot find 'grib_ls' executable. Is ecCodes installed?")

        # Step 1: Let us read the inventory
        params <- c("shortName", "dataDate", "dataTime", "endStep", "typeOfLevel", "level",
                    "perturbationNumber", "numberOfForecastsInEnsemble")
        cmd <- sprintf("%s -j -p %s %s", gls, paste(params, collapse = ","), file)
        inv <- tryCatch(paste(system(cmd, intern = TRUE), collapse = ""),
                        warning = function(w) warning(w),
                        error   = function(e) stop("Problems getting GRIB inventory calling '",
                                                   cmd, "'", sep = ""))
        inv <- fromJSON(inv)[[1]]
        inv <- bind_rows(lapply(inv, function(x) data.frame(x)))

        # Do we need the perturbationNumber?
        if (all(inv$numberOfForecastsInEnsemble == 0))
            inv <- transform(inv, perturbationNumber = NULL, numberOfForecastsInEnsemble = NULL)

        # Renaming
        renaming <- c("shortName" = "param",
                      "typeOfLevel" = "levtype",
                      "perturbationNumber" = "number",
                      "endStep" = "step")
        rename_idx <- match(names(inv), names(renaming))
        names(inv)[which(!is.na(rename_idx))] <- renaming[na.omit(rename_idx)]

        # Convert some of the variables we got
        inv <- within(inv, {
                  init     = as.POSIXct(sprintf("%08d %04d", dataDate, dataTime),
                                        format = "%Y%m%d %H%M", tz = "UTC");
                  valid    = init + 3600 * step;
                  dataDate = dataTime = NULL;
                })
    }

    # Renaming variables and reduce information in 'inv'
    inv <- eupp_interpolate_grib_rename_variables(inv)
    if (wide) {
        inv <- subset(inv, select = c(if (ignore_init) NULL else "init", "valid",
                                      if (ignore_init) NULL else "step", "param"))
    }

    # Reading GRIB file; interpolate data
    data <- read_stars(file)
    if (!(if ("band" %in% names(dim(data))) dim(data)["band"] else 1) == nrow(inv))
        stop("Mismatch between grib inventory (field information) and number of messages read!")

    # Transform positions to the CRS of the stars object
    attransformed <- st_transform(at, crs = st_crs(data))

    res <- list()
    for (i in seq_len(nrow(at))) {
        # Interpolate data, modify return, combine with meta information from GRIB
        ip <- as.data.frame(st_extract(data, at = attransformed[i, ], bilinear = bilinear))
        names(ip)[grepl(file, names(ip))] <- "value" # Renaming
        if (!is.null(atname) && atname %in% names(at)) ip[[atname]] <- at[[i, atname]]
        res[[i]] <- cbind(inv, ip[, c("geometry", "value",
                          if (!is.null(atname) && atname %in% names(ip)) atname else NULL)])
    }
    res <- bind_rows(res)

    # Sort columns
    if (wide == TRUE) {
        res_wide  <- as.data.frame(pivot_wider(res, names_from = "param", values_from = "value"))
        main_cols <- which(names(res_wide) %in% names(res))
        res       <- res_wide[, c(names(res_wide)[main_cols], sort(names(res_wide)[-main_cols]))]
    }

    return(res)

}


eupp_interpolate_grib_rename_variables <- function(x) {
    stopifnot(is.data.frame(x), "param" %in% names(x))

    # Vector used for renaming
    renaming <- c("2t" = "t2m",
                  "10u" = "u10m",
                  "10v" = "v10m",
                  "10fg" = "fg10m")
    idx <- match(x$param, names(renaming))
    x$param[!is.na(idx)] <- renaming[idx[!is.na(idx)]]

    # Renaming pressure level variables
    idx <- grep("^isobaricInhPa$", x$levtype)
    if (length(idx) > 0) x$param[idx] <- sprintf("%s%d", x$param[idx], x$level[idx])

    # Adding member number in case this is an ensemble data set
    if ("number" %in% names(x) && !all(is.na(x$number))) x$param <- paste(x$param, x$number, sep = "_")

    return(x)
}





