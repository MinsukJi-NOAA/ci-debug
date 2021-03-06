! This code is part of Radiative Transfer for Energetics (RTE)
!
! Contacts: Robert Pincus and Eli Mlawer
! email:  rrtmgp@aer.com
!
! Copyright 2015-2018,  Atmospheric and Environmental Research and
! Regents of the University of Colorado.  All right reserved.
!
! Use and duplication is permitted under the terms of the
!    BSD 3-clause license, see http://opensource.org/licenses/BSD-3-Clause
! -------------------------------------------------------------------------------------------------
!
!  Contains a single routine to compute direct and diffuse fluxes of solar radiation given
!    atmospheric optical properties on a spectral grid
!    information about vertical ordering
!    boundary conditions
!      solar zenith angle, spectrally-resolved incident colimated flux, surface albedos for direct and diffuse radiation
!    optionally, a boundary condition for incident diffuse radiation
!
! It is the user's responsibility to ensure that boundary conditions (incident fluxes, surface albedos) are on the same
!   spectral grid as the optical properties.
!
! Final output is via user-extensible ty_fluxes which must reduce the detailed spectral fluxes to
!   whatever summary the user needs.
!
! The routine does error checking and choses which lower-level kernel to invoke based on
!   what kinds of optical properties are supplied
!
! -------------------------------------------------------------------------------------------------
module mo_rte_sw
  use mo_rte_kind,      only: wp, wl
  use mo_rte_config,    only: check_extents, check_values
  use mo_rte_util_array,only: any_vals_less_than, any_vals_outside, extents_are, zero_array
  use mo_optical_props, only: ty_optical_props, &
                              ty_optical_props_arry, ty_optical_props_1scl, ty_optical_props_2str, ty_optical_props_nstr
  use mo_fluxes,        only: ty_fluxes, ty_fluxes_broadband
  use mo_rte_solver_kernels, &
                        only: apply_BC, sw_solver_noscat, sw_solver_2stream, sw_solver_2stream_integrated
  implicit none
  private

  public :: rte_sw

contains
  ! --------------------------------------------------
  function rte_sw(atmos, top_at_1,                 &
                  mu0, inc_flux,                   &
                  sfc_alb_dir, sfc_alb_dif,        &
                  fluxes, inc_flux_dif) result(error_msg)
    class(ty_optical_props_arry), intent(in   ) :: atmos           ! Optical properties provided as arrays
    logical,                      intent(in   ) :: top_at_1        ! Is the top of the domain at index 1?
                                                                   ! (if not, ordering is bottom-to-top)
    real(wp), dimension(:),       intent(in   ) :: mu0             ! cosine of solar zenith angle (ncol)
    real(wp), dimension(:,:),     intent(in   ) :: inc_flux,    &  ! incident flux at top of domain [W/m2] (ncol, ngpt)
                                                   sfc_alb_dir, &  ! surface albedo for direct and
                                                   sfc_alb_dif     ! diffuse radiation (nband, ncol)
    class(ty_fluxes),             intent(inout) :: fluxes          ! Class describing output calculations
    real(wp), dimension(:,:), optional, &
                                  intent(in   ) :: inc_flux_dif    ! incident diffuse flux at top of domain [W/m2] (ncol, ngpt)
    character(len=128)                          :: error_msg       ! If empty, calculation was successful
    ! --------------------------------
    !
    ! Local variables
    !
    integer :: ncol, nlay, ngpt, nband
    integer :: icol, igpt

    real(wp), dimension(:,:,:), allocatable :: gpt_flux_up, gpt_flux_dn, gpt_flux_dir
    real(wp), dimension(:,:),   allocatable :: sfc_alb_dir_gpt, sfc_alb_dif_gpt
    real(wp), dimension(:,:),   allocatable :: inc_flux_diffuse ! Temporary use when using _integrated kernels
    real(wp), dimension(:,:),   pointer     :: flux_dn_loc, flux_up_loc, flux_dir_loc
    ! ------------------------------------------------------------------------------------
    ncol  = atmos%get_ncol()
    nlay  = atmos%get_nlay()
    ngpt  = atmos%get_ngpt()
    nband = atmos%get_nband()
    error_msg = ""

    ! ------------------------------------------------------------------------------------
    !
    ! Error checking -- consistency of sizes and validity of values
    !
    ! --------------------------------
    if(.not. fluxes%are_desired()) &
      error_msg = "rte_sw: no space allocated for fluxes"

    !
    ! Sizes of input arrays
    !
    if(check_extents) then
      if(.not. extents_are(mu0, ncol)) &
        error_msg = "rte_sw: mu0 inconsistently sized"
      if(.not. extents_are(inc_flux, ncol, ngpt)) &
        error_msg = "rte_sw: inc_flux inconsistently sized"
      if(.not. extents_are(sfc_alb_dir, nband, ncol)) &
        error_msg = "rte_sw: sfc_alb_dir inconsistently sized"
      if(.not. extents_are(sfc_alb_dif, nband, ncol)) &
        error_msg = "rte_sw: sfc_alb_dif inconsistently sized"
      if(present(inc_flux_dif)) then
        if(.not. extents_are(inc_flux_dif, ncol, ngpt)) &
          error_msg = "rte_sw: inc_flux_dif inconsistently sized"
      end if
    end if

    !
    ! Values of input arrays
    !
    if(check_values) then
      if(any_vals_outside(mu0, 0._wp, 1._wp)) &
        error_msg = "rte_sw: one or more mu0 <= 0 or > 1"
      if(any_vals_less_than(inc_flux, 0._wp)) &
        error_msg = "rte_sw: one or more inc_flux < 0"
      if(any_vals_outside(sfc_alb_dir,  0._wp, 1._wp)) &
        error_msg = "rte_sw: sfc_alb_dir out of bounds [0,1]"
      if(any_vals_outside(sfc_alb_dif,  0._wp, 1._wp)) &
        error_msg = "rte_sw: sfc_alb_dif out of bounds [0,1]"
      if(present(inc_flux_dif)) then
        if(any_vals_less_than(inc_flux_dif, 0._wp)) &
          error_msg = "rte_sw: one or more inc_flux_dif < 0"
      end if
    end if


    if(len_trim(error_msg) > 0) then
      if(len_trim(atmos%get_name()) > 0) &
        error_msg = trim(atmos%get_name()) // ': ' // trim(error_msg)
      return
    end if

    ! ------------------------------------------------------------------------------------
    select type(fluxes)
      type is (ty_fluxes_broadband)
        !
        ! Broadband, spectrally integrated profiles get their own solvers that integrate in place
        !   Fluxes class has three possible outputs; allocate memory for local use if one or
        !   more haven't been requested
        !   OpenMP and OpenACC directives needed here
        !
        if(associated(fluxes%flux_up)) then
          flux_up_loc => fluxes%flux_up
        else
          allocate(flux_up_loc(ncol, nlay+1))
          !$acc        enter data create(   flux_up_loc)
          !$omp target enter data map(alloc:flux_up_loc)
        end if
        if(associated(fluxes%flux_dn)) then
          flux_dn_loc => fluxes%flux_dn
        else
          allocate(flux_dn_loc(ncol, nlay+1))
          !$acc        enter data create(   flux_dn_loc)
          !$omp target enter data map(alloc:flux_dn_loc)
        end if
        if(associated(fluxes%flux_dn_dir)) then
          flux_dir_loc => fluxes%flux_dn_dir
        else
          allocate(flux_dir_loc(ncol, nlay+1))
          !$acc        enter data create(   flux_dir_loc)
          !$omp target enter data map(alloc:flux_dir_loc)
        end if
        !
        ! Diffuse flux - will use values in optional arg or be set to 0
        !
        allocate(inc_flux_diffuse(ncol, ngpt))
        !$acc        enter data create(   inc_flux_diffuse)
        !$omp target enter data map(alloc:inc_flux_diffuse)
      class default
        allocate(gpt_flux_up (ncol, nlay+1, ngpt), &
                 gpt_flux_dn (ncol, nlay+1, ngpt), &
                 gpt_flux_dir(ncol, nlay+1, ngpt))
        !$acc        enter data create(   gpt_flux_up, gpt_flux_dn, gpt_flux_dir)
        !$omp target enter data map(alloc:gpt_flux_up, gpt_flux_dn, gpt_flux_dir)
    end select
    allocate(sfc_alb_dir_gpt(ncol, ngpt), sfc_alb_dif_gpt(ncol, ngpt))
    !$acc        enter data create(   sfc_alb_dir_gpt, sfc_alb_dif_gpt)
    !$omp target enter data map(alloc:sfc_alb_dir_gpt, sfc_alb_dif_gpt)
    ! ------------------------------------------------------------------------------------
    ! Lower boundary condition -- expand surface albedos by band to gpoints
    !   and switch dimension ordering

    !$acc enter data create(sfc_alb_dir_gpt, sfc_alb_dif_gpt)
    !$omp target enter data map(alloc:sfc_alb_dir_gpt, sfc_alb_dif_gpt)
    call expand_and_transpose(atmos, sfc_alb_dir, sfc_alb_dir_gpt)
    call expand_and_transpose(atmos, sfc_alb_dif, sfc_alb_dif_gpt)
    ! ------------------------------------------------------------------------------------
    !
    ! Compute the radiative transfer...
    !
    !
    !$acc        enter data copyin(mu0, inc_flux)
    !$omp target enter data map(to:mu0, inc_flux)
    select type(fluxes)
      type is (ty_fluxes_broadband)
        !
        ! Boundary conditions for direct flux are applied in the solver
        !
        !
        if(present(inc_flux_dif)) then
          !
          ! OpenACC/OpenMP directives needed here
          !
          !$acc                         parallel loop    collapse(2)
          !$omp target teams distribute parallel do simd collapse(2)
          do igpt = 1, ngpt
            do icol = 1, ncol
              inc_flux_diffuse(icol, igpt) = inc_flux_dif(icol, igpt)
            end do
          end do
        else
          call zero_array(ncol, ngpt, inc_flux_diffuse)
        end if
      class default
        !
        ! Boundary conditions are applied to the spectrally-resolved flux fields
        !
        call apply_BC(ncol, nlay, ngpt, logical(top_at_1, wl),   inc_flux, mu0, gpt_flux_dir)
        !$acc        exit data delete(     inc_flux)
        !$omp target exit data map(release:inc_flux)
        if(present(inc_flux_dif)) then
          !$acc        enter data copyin(inc_flux_dif) !!! <--- Why are these needed?
          !$omp target enter data map(to:inc_flux_dif)
          call apply_BC(ncol, nlay, ngpt, logical(top_at_1, wl), inc_flux_dif,  gpt_flux_dn )
          !$acc        exit data delete(     inc_flux_dif)
          !$omp target exit data map(release:inc_flux_dif)
        else
          call apply_BC(ncol, nlay, ngpt, logical(top_at_1, wl),                gpt_flux_dn )
        end if
    end select

    select type (atmos)
      class is (ty_optical_props_1scl)
        !
        ! Direct beam only
        !
        !$acc enter data copyin(atmos, atmos%tau)
        !$omp target enter data map(to:atmos%tau)
        error_msg =  atmos%validate()
        if(len_trim(error_msg) > 0) return
        call sw_solver_noscat(ncol, nlay, ngpt, logical(top_at_1, wl), &
                              atmos%tau, mu0,                          &
                              gpt_flux_dir)
        !$acc exit data delete(atmos%tau, atmos)
        !$omp target exit data map(release:atmos%tau)
        !
        ! No diffuse flux - should set arrays to 0.
        !
      class is (ty_optical_props_2str)
        !
        ! two-stream calculation with scattering
        !
        !$acc enter data copyin(atmos, atmos%tau, atmos%ssa, atmos%g)
        !$omp target enter data map(to:atmos%tau, atmos%ssa, atmos%g)
        error_msg =  atmos%validate()
        if(len_trim(error_msg) > 0) return
        select type(fluxes)
          type is (ty_fluxes_broadband)
            call sw_solver_2stream_integrated( &
                                   ncol, nlay, ngpt, logical(top_at_1, wl), &
                                   atmos%tau, atmos%ssa, atmos%g, mu0,      &
                                   sfc_alb_dir_gpt, sfc_alb_dif_gpt,        &
                                   inc_flux, inc_flux_diffuse,              &
                                   flux_up_loc, flux_dn_loc, flux_dir_loc)
            !$acc exit data delete(inc_flux, inc_flux_diffuse)
            !$omp target exit data map(release:inc_flux, inc_flux_diffuse)
          class default
            call sw_solver_2stream(ncol, nlay, ngpt, logical(top_at_1, wl), &
                                   atmos%tau, atmos%ssa, atmos%g, mu0,      &
                                   sfc_alb_dir_gpt, sfc_alb_dif_gpt,        &
                                   gpt_flux_up, gpt_flux_dn, gpt_flux_dir)
        end select
        !$acc        exit data delete(     atmos%tau, atmos%ssa, atmos%g, atmos)
        !$omp target exit data map(release:atmos%tau, atmos%ssa, atmos%g)
        !$acc        exit data delete(     sfc_alb_dir_gpt, sfc_alb_dif_gpt)
        !$omp target exit data map(release:sfc_alb_dir_gpt, sfc_alb_dif_gpt)
      class is (ty_optical_props_nstr)
        !
        ! n-stream calculation
        !
        ! not yet implemented so fail
        !
        error_msg = 'sw_solver(...ty_optical_props_nstr...) not yet implemented'
    end select
    if(len_trim(error_msg) > 0) then
      if(len_trim(atmos%get_name()) > 0) &
        error_msg = trim(atmos%get_name()) // ': ' // trim(error_msg)
      return
    end if
    !
    ! ...and reduce spectral fluxes to desired output quantities
    !
    select type(fluxes)
      type is (ty_fluxes_broadband)
        !
        ! Components of ty_fluxes already contain spectral integral
        !
        if(.not. associated(fluxes%flux_up)) then
          !$acc        exit data delete(     flux_up_loc)
          !$omp target exit data map(release:flux_up_loc)
          deallocate(flux_up_loc)
        end if
        if(.not. associated(fluxes%flux_dn)) then
          !$acc        exit data delete(     flux_dn_loc)
          !$omp target exit data map(release:flux_dn_loc)
          deallocate(flux_dn_loc)
        end if
        if(.not. associated(fluxes%flux_dn_dir)) then
          !$acc        exit data delete(     flux_dir_loc)
          !$omp target exit data map(release:flux_dir_loc)
          deallocate(flux_dir_loc)
        end if
      class default
        error_msg = fluxes%reduce(gpt_flux_up, gpt_flux_dn, atmos, top_at_1, gpt_flux_dir)
        !$acc        exit data delete(     gpt_flux_up, gpt_flux_dn, gpt_flux_dir)
        !$omp target exit data map(release:gpt_flux_up, gpt_flux_dn, gpt_flux_dir)
    end select
    !$acc exit data delete(mu0)
    !$omp target exit data map(release:mu0)
  end function rte_sw
  !--------------------------------------------------------------------------------------------------------------------
  !
  ! Expand from band to g-point dimension, transpose dimensions (nband, ncol) -> (ncol,ngpt)
  !
  subroutine expand_and_transpose(ops,arr_in,arr_out)
    class(ty_optical_props),  intent(in ) :: ops
    real(wp), dimension(:,:), intent(in ) :: arr_in  ! (nband, ncol)
    real(wp), dimension(:,:), intent(out) :: arr_out ! (ncol, igpt)
    ! -------------
    integer :: ncol, nband, ngpt
    integer :: icol, iband, igpt
    integer, dimension(2,ops%get_nband()) :: limits

    ncol  = size(arr_in, 2)
    nband = ops%get_nband()
    ngpt  = ops%get_ngpt()
    limits = ops%get_band_lims_gpoint()
    !$acc parallel loop collapse(2) copyin(arr_in, limits)
    !$omp target teams distribute parallel do simd collapse(2) map(to:arr_in, limits)
    do iband = 1, nband
      do icol = 1, ncol
        do igpt = limits(1, iband), limits(2, iband)
          arr_out(icol, igpt) = arr_in(iband,icol)
        end do
      end do
    end do

  end subroutine expand_and_transpose
end module mo_rte_sw
