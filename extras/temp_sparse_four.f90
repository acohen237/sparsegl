! --------------------------------------------------
SUBROUTINE sparse_four (bn,bs,ix,iy,gam,nobs,nvars,x,y,pf,dfmax,pmax,nlam,flmin,ulam,&
     eps,maxit,nalam,beta,activeGroup,nbeta,alam,npass,jerr,alsparse)
  ! --------------------------------------------------
  USE mySubby
  IMPLICIT NONE
  ! - - - arg types - - -
  DOUBLE PRECISION, PARAMETER :: big=9.9E30
  DOUBLE PRECISION, PARAMETER :: mfl = 1.0E-6
  INTEGER, PARAMETER :: mnlam = 6
  INTEGER:: isDifZero
  INTEGER:: mnl
  INTEGER:: bn
  INTEGER::bs(bn)
  INTEGER::ix(bn)
  INTEGER::iy(bn)
  INTEGER:: nobs
  INTEGER::nvars
  INTEGER::dfmax
  INTEGER::pmax
  INTEGER::nlam
  INTEGER::nalam
  INTEGER::npass
  INTEGER::jerr
  INTEGER::maxit
  INTEGER:: activeGroup(pmax)
  INTEGER::nbeta(nlam)
  DOUBLE PRECISION:: flmin
  DOUBLE PRECISION::eps
  DOUBLE PRECISION:: x(nobs,nvars)
  DOUBLE PRECISION::y(nobs)
  DOUBLE PRECISION::pf(bn)
  DOUBLE PRECISION::ulam(nlam)
  DOUBLE PRECISION::gam(bn)
  DOUBLE PRECISION::beta(nvars,nlam)
  DOUBLE PRECISION::alam(nlam)
  DOUBLE PRECISION::alsparse ! Should be alpha for the sparsity weight
  ! - - - local declarations - - -
  DOUBLE PRECISION:: max_gam
  ! DOUBLE PRECISION::d
  ! DOUBLE PRECISION::t ! No longer using this
  DOUBLE PRECISION::maxDif
  ! DOUBLE PRECISION::unorm ! No longer using this for ls_new
  DOUBLE PRECISION::al
  DOUBLE PRECISION::alf
  ! DOUBLE PRECISION::sg
  DOUBLE PRECISION, DIMENSION (:), ALLOCATABLE :: b
  DOUBLE PRECISION, DIMENSION (:), ALLOCATABLE :: oldbeta
  DOUBLE PRECISION, DIMENSION (:), ALLOCATABLE :: r ! Residue y-beta_k*x etc
  ! DOUBLE PRECISION, DIMENSION (:), ALLOCATABLE :: oldb
  DOUBLE PRECISION, DIMENSION (:), ALLOCATABLE :: u ! No longer using this for update step, but still need for other parts
  ! DOUBLE PRECISION, DIMENSION (:), ALLOCATABLE :: dd
  INTEGER, DIMENSION (:), ALLOCATABLE :: activeGroupIndex
  INTEGER:: g
  INTEGER::j
  INTEGER::l
  INTEGER::ni
  INTEGER::me
  INTEGER::startix
  INTEGER::endix
  ! - - - Aaron's declarations
  ! DOUBLE PRECISION::snorm
  DOUBLE PRECISION::t_for_s(bn) ! this is for now just 1/gamma
  ! DOUBLE PRECISION::tea ! this takes the place of 't' in the update step for ls
  ! DOUBLE PRECISION, DIMENSION (:), ALLOCATABLE :: s ! takes the place of 'u' in update for ls
  ! INTEGER::soft_g ! this is an iterating variable 'vectorizing' the soft thresholding operator
  INTEGER::vl_iter ! for iterating over columns(?) of x*r
  INTEGER::kill_count
  ! - - - begin - - -
  ! - - - local declarations - - -
  DOUBLE PRECISION:: tlam
  DOUBLE PRECISION:: lama
  DOUBLE PRECISION:: lam1ma
  INTEGER:: violation
  INTEGER:: is_in_E_set(bn)
  DOUBLE PRECISION:: ga(bn) ! What is this for??
  DOUBLE PRECISION:: vl(nvars) ! What is this for?
  DOUBLE PRECISION:: al0
  ! - - - allocate variables - - -
  ALLOCATE(b(1:nvars))
  ALLOCATE(oldbeta(1:nvars))
  ALLOCATE(r(1:nobs))
  ALLOCATE(activeGroupIndex(1:bn))
  !    ALLOCATE(al_sparse)
  ! - - - checking pf - ! pf is the relative penalties for each group
  IF(maxval(pf) <= 0.0D0) THEN
     jerr=10000
     RETURN
  ENDIF
  pf=max(0.0D0,pf)
  ! - - - some initial setup - - -
  is_in_E_set = 0
  al = 0.0D0
  mnl = Min (mnlam, nlam)
  r = y
  b = 0.0D0
  oldbeta = 0.0D0
  activeGroup = 0
  kill_count = 0
  activeGroupIndex = 0
  npass = 0 ! This is a count, correct?
  ni = npass ! This controls so-called "outer loop"
  alf = 0.0D0
  t_for_s = 1/gam ! might need to use a loop if no vectorization.........
  ! --------- lambda loop ----------------------------
  IF(flmin < 1.0D0) THEN ! THIS is the default...
     flmin = Max (mfl, flmin) ! just sets a threshold above zero
     alf=flmin**(1.0D0/(nlam-1.0D0))
  ENDIF
  ! PRINT *, alf
  vl = matmul(r, x)/nobs ! Note r gets updated in middle and inner loop
  al0 = 0.0D0
  DO g = 1,bn ! For each group...
     ALLOCATE(u(bs(g)))
     u = vl(ix(g):iy(g))
     ga(g) = sqrt(dot_product(u,u))
     DEALLOCATE(u)
  ENDDO
  DO vl_iter = 1,nvars
     al0 = max(al0, abs(vl(vl_iter))) ! Infty norm of X'y, big overkill for lam_max
  ENDDO
  ! PRINT *, alsparse
  al = al0 ! / (1-alsparse) ! this value ensures all betas are 0 , divide by 1-a?
  l = 0
  tlam = 0.0D0
  DO WHILE (l < nlam) !! This is the start of the loop over all lambda values...
     ! print *, "l = ", l
     ! print *, "al = ", al
     ! IF(kill_count > 1000) RETURN
     ! kill_count = kill_count + 1
     al0 = al ! store old al value on subsequent loops, first set to al
     IF(flmin>=1.0D0) THEN ! user supplied lambda value, break out of everything
        l = l+1
        al=ulam(l)
        ! print *, "This is at the flmin step of the while loop"
     ELSE
        IF(l > 1) THEN ! have some active groups
          al=al*alf
          tlam = max((2.0*al-al0), 0.0) ! Here is the strong rule...
          l = l+1
          ! print *, "This is the l>1 step of while loop"
        ELSE IF(l==0) THEN
          al=al*.99
          tlam=al
          ! Trying to find an active group
        ENDIF
     ENDIF
     lama = al*alsparse
     lam1ma = al*(1-alsparse)
     ! This is the start of the algorithm, for a given lambda...
     call strong_rule (is_in_E_set, ga, pf, tlam, alsparse) !implementing strong rule, updates is_in_E_set
     ! --------- outer loop ---------------------------- !
     DO
        IF(ni>0) THEN
           DO j=1,ni
              g=activeGroup(j)
              oldbeta(ix(g):iy(g))=b(ix(g):iy(g))
           ENDDO
        ENDIF
        ! --middle loop-------------------------------------
        DO
           ! print *, "This is where we enter the middle loop"
           npass=npass+1
           maxDif=0.0D0
           isDifZero = 0 !Boolean to check if b-oldb nonzero. Unnec, in fn.
           DO j=1,ni
              g=activeGroup(j)
              startix=ix(g)
              endix=iy(g)
              call update_step(bs(g), startix, endix, b, lama, t_for_s(g), pf(g), lam1ma, x,&
                  isDifZero, nobs, r, gam(g), maxDif, nvars)
              IF(activeGroupIndex(g)==0 .and. isDifZero == 1) THEN
                    ni=ni+1
                    IF(ni>pmax) EXIT
                    activeGroupIndex(g)=ni
                    activeGroup(ni)=g
              ENDIF
           ENDDO ! End middle loop
           IF (ni > pmax) EXIT
           IF (maxDif < eps) EXIT
           IF(npass > maxit) THEN !Is this needed?
              jerr=-l
              RETURN
           ENDIF
        ENDDO ! End middle loop
        IF(ni>pmax) EXIT
        !--- final check ------------------------ ! This checks which violate KKT condition
        ! PRINT *, "Here is where the final check starts"
        violation = 0
        max_gam = maxval(gam)
        IF(any((max_gam*(b-oldbeta)/(1+abs(b)))**2 >= eps)) violation = 1 !has beta moved globally
        IF (violation == 1) CYCLE
        vl = matmul(r, x)/nobs
        call strong_rule(!shit lost my focus!!!!!!
        call kkt_check(is_in_E_set, violation, bn, ix, iy, vl, pf, lam1ma, bs, lama) ! kkt subroutine
        IF(violation == 1) CYCLE ! This goes all the way back to outer loop
        EXIT
     ENDDO ! Ends outer loop
     !---------- final update variable and save results------------
     IF(l==0) THEN
        IF(maxval(is_in_E_set)==0) THEN
           CYCLE ! don't save anything, we're still decrementing lambda
        ELSE
           l=2
           alam(1) = al / max(alf,.99) ! store previous, larger value
        ENDIF
     ENDIF
     ! PRINT *, "Here is where the final update starts"
     IF(ni>pmax) THEN
        jerr=-10000-l
        EXIT
     ENDIF
     IF(ni>0) THEN
        DO j=1,ni
           g=activeGroup(j)
           beta(ix(g):iy(g),l)=b(ix(g):iy(g))
        ENDDO
     ENDIF
     nbeta(l)=ni
     alam(l)=al
     nalam=l
     IF (l < mnl) CYCLE
     me=0
     DO j=1,ni
        g=activeGroup(j)
        IF(any(beta(ix(g):iy(g),l)/=0.0D0)) me=me+1
     ENDDO
     IF(me>dfmax) EXIT
  ENDDO ! end lambda loop
  DEALLOCATE(b,oldbeta,r,activeGroupIndex)
  RETURN
END SUBROUTINE sparse_four
