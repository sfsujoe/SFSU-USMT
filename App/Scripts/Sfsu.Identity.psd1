@{
    # AD attribute containing the university ID. This is independent of login names.
    IdAttribute = 'sAMAccountName'
    # Bare technician logins use this suffix. Full UPNs must use an allowed suffix.
    DefaultLoginSuffix = 'sfsu.edu'
    AllowedLoginSuffixes = @('sfsu.edu')
}
