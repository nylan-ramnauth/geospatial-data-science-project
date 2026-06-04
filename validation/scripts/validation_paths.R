# Shared path helpers for validation scripts.

validation_script_path <- function(fallback = NULL) {
  script_arg <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(script_arg) > 0) {
    return(normalizePath(sub("^--file=", "", script_arg[[1]]), mustWork = TRUE))
  }
  if (!is.null(fallback)) {
    return(normalizePath(fallback, mustWork = TRUE))
  }
  normalizePath(getwd(), mustWork = TRUE)
}

validation_repo_root <- function(start = getwd()) {
  current <- normalizePath(start, mustWork = TRUE)
  if (file.info(current)$isdir != TRUE) {
    current <- dirname(current)
  }

  repeat {
    if (
      file.exists(file.path(current, ".here")) &&
        dir.exists(file.path(current, "Builder")) &&
        dir.exists(file.path(current, "validation"))
    ) {
      return(current)
    }

    parent <- dirname(current)
    if (identical(parent, current)) {
      stop("Could not locate Reliability-Assessment repo root from: ", start)
    }
    current <- parent
  }
}

validation_env_path <- function(name, default) {
  value <- Sys.getenv(name, unset = "")
  if (nzchar(value)) {
    return(normalizePath(value, mustWork = FALSE))
  }
  normalizePath(default, mustWork = FALSE)
}

validation_paths <- function(repo_root, section) {
  repo_root <- normalizePath(repo_root, mustWork = TRUE)
  validation_dir <- file.path(repo_root, "validation")
  section_dir <- file.path(validation_dir, section)
  pypsa_earth_dir <- validation_env_path(
    "PYPSA_EARTH_DIR",
    file.path(dirname(repo_root), "pypsa-earth")
  )

  list(
    repo_root = repo_root,
    validation_dir = validation_dir,
    section_dir = section_dir,
    data_dir = file.path(section_dir, "data"),
    reports_dir = file.path(section_dir, "reports"),
    scripts_dir = file.path(section_dir, "scripts"),
    figures_dir = file.path(section_dir, "figures"),
    pypsa_earth_dir = pypsa_earth_dir,
    eskom_hourly_csv = validation_env_path(
      "ESKOM_HOURLY_CSV",
      file.path(pypsa_earth_dir, "data", "za_validation", "eskom_2023_hourly_clean.csv")
    )
  )
}

validation_section_data <- function(paths, section, filename) {
  file.path(paths$validation_dir, section, "data", filename)
}
